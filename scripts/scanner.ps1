<#
=====================================================================
 ANDROID BLOATWARE SCANNER v2  -  any phone / tablet, Android 9 - 16
=====================================================================
 Reads every package on the device in ONE adb round-trip, classifies
 each one (category + risk) and writes into output\<device>\ :

   latest.json                 full scan (used by the GUI)
   report.md                   human readable report
   auto_remove_bloatware.ps1   editable removal list (calls remover.ps1)
   history\scan_<ts>.json      every previous scan

 Risk levels (labels only - NOTHING is blocked, every package is listed)
   safe      known junk / ads / demos / stubs
   optional  real apps (Google, OEM, carrier) - fine if you use alternatives
   caution   services; removing may break a feature (camera, sync, OTA...)
   keep      core OS; removing can break boot/UI (recover: factory reset)

 Levels decide which lines start ACTIVE in the generated list:
   Recommended  safe                          (default)
   Aggressive   safe + optional               (all Google/OEM apps)
   Maximum      safe + optional + caution     (everything except core OS)
 Your own installed apps and 'keep' packages are always listed, commented.

 Usage
   .\scanner.ps1                      scan the only connected device
   .\scanner.ps1 -Serial <id>         pick a device when several are connected
   .\scanner.ps1 -Level Aggressive  start with Google/OEM apps active too
   .\scanner.ps1 -NoScript            scan + report only
   .\scanner.ps1 -ListDevices         list adb devices (JSON, used by the GUI)
   .\scanner.ps1 -h                   this help

 Re-scanning keeps your edits: any package you commented / uncommented
 in a previous auto_remove_bloatware.ps1 keeps that state. Passing
 -Level explicitly starts fresh (old list is backed up to history\).
=====================================================================
#>
param(
    [Alias('h')][switch]$Help,
    [string]$Serial,
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\output'),
    [ValidateSet('Recommended', 'Aggressive', 'Maximum')][string]$Level = 'Recommended',
    [switch]$NoScript,
    [switch]$ListDevices
)

if ($Help) {
    if ((Get-Content -Raw $PSCommandPath) -match '(?s)<#(.*?)#>') { Write-Host $Matches[1].Trim() }
    exit 0
}

$ErrorActionPreference = 'Continue'
$MinSdk = 28   # Android 9

# =====================================================================
# CLASSIFICATION RULES
#   pattern | category | risk | label
#   'pkg'   exact match (always wins)
#   'pkg*'  prefix match (longest prefix wins, then keyword heuristics)
# categories: system google oem chipset carrier thirdparty
# Packages matching nothing become 'user' (installed by you) or 'unknown'.
# =====================================================================
$RulesText = @'
# ---------------- Android core ----------------
android                                        | system | keep     | Android framework
android.*                                      | system | keep     | Framework overlay
com.android.*                                  | system | caution  | AOSP component
com.android.internal.*                         | system | keep     | Display / navigation overlay
com.android.theme.*                            | system | keep     | Theme overlay
com.android.systemui*                          | system | keep     | System UI
com.android.settings*                          | system | keep     | Settings
com.android.phone*                             | system | keep     | Phone services
com.android.server.telecom*                    | system | keep     | Telecom
com.android.providers.*                        | system | keep     | Content provider
com.android.providers.partnerbookmarks         | system | optional | Partner bookmarks
com.android.providers.partnerbrowsercustomizations | system | optional | Partner browser config
com.android.shell                              | system | keep     | Shell
com.android.packageinstaller                   | system | keep     | Package installer
com.android.permissioncontroller               | system | keep     | Permission controller
com.android.inputdevices                       | system | keep     | Input devices
com.android.keychain                           | system | keep     | Keychain
com.android.location.fused                     | system | keep     | Fused location
com.android.externalstorage                    | system | keep     | External storage
com.android.mtp                                | system | keep     | USB file transfer (MTP)
com.android.se                                 | system | keep     | Secure element
com.android.certinstaller                      | system | keep     | Certificate installer
com.android.wifi.*                             | system | keep     | Wi-Fi resources
com.android.uwb.*                              | system | keep     | UWB resources
com.android.networkstack*                      | system | keep     | Network stack
com.android.bluetooth                          | system | keep     | Bluetooth
com.android.nfc                                | system | keep     | NFC
com.android.launcher3                          | system | keep     | Launcher
com.android.documentsui                        | system | keep     | Files picker
com.android.vpndialogs                         | system | keep     | VPN dialogs
com.android.cts.*                              | system | keep     | CTS shim
com.android.localtransport                     | system | keep     | Backup transport
com.android.carrierconfig*                     | system | keep     | Carrier config
com.android.ons                                | system | keep     | Opportunistic network
com.android.mms.service                        | system | keep     | MMS service
com.android.smspush                            | system | keep     | WAP push
com.android.dialer                             | system | keep     | Dialer
com.android.contacts                           | system | caution  | Contacts
com.android.messaging                          | system | caution  | Messaging
com.android.camera2                            | system | caution  | Camera
com.android.stk                                | system | caution  | SIM toolkit
com.android.cellbroadcastreceiver*             | system | caution  | Emergency alerts
com.android.emergency                          | system | caution  | Emergency info
com.android.storagemanager                     | system | caution  | Storage manager
com.android.backupconfirm                      | system | caution  | Backup confirm
com.android.sharedstoragebackup                | system | caution  | Shared storage backup
com.android.wallpaperbackup                    | system | caution  | Wallpaper backup
com.android.pacprocessor                       | system | caution  | Proxy auto-config
com.android.proxyhandler                       | system | caution  | Proxy handler
com.android.companiondevicemanager             | system | caution  | Companion devices (watches)
com.android.printspooler                       | system | caution  | Print spooler
com.android.htmlviewer                         | system | caution  | HTML viewer
com.android.simappdialog                       | system | caution  | SIM app dialog
com.android.carrierdefaultapp                  | system | caution  | Carrier default app
com.android.imsserviceentitlement              | system | caution  | IMS entitlement
com.android.hotspot2.osulogin                  | system | caution  | Passpoint login
com.android.cameraextensions                   | system | caution  | Camera extensions
com.android.apppredictionservice               | system | caution  | App prediction
com.android.wallpapercropper                   | system | caution  | Wallpaper cropper
com.android.soundpicker                        | system | caution  | Ringtone picker
com.android.managedprovisioning               | system | caution  | Work profile setup
com.android.statementservice                   | system | caution  | App links verifier
com.android.bluetoothmidiservice               | system | caution  | Bluetooth MIDI
com.android.calllogbackup                      | system | optional | Call log backup
com.android.dynsystem                          | system | optional | Dynamic system (GSI)
com.android.traceur                            | system | optional | System tracing
com.android.egg                                | system | safe     | Android easter egg
com.android.dreams.*                           | system | optional | Screensaver
com.android.wallpaper.livepicker               | system | optional | Live wallpaper picker
com.android.bips                               | system | optional | Default print service
com.android.bookmarkprovider                   | system | optional | Bookmark provider
com.android.musicfx                            | system | optional | Audio effects
com.android.apps.tag                           | system | optional | NFC tag viewer
com.android.hotwordenrollment.*                | system | optional | OK Google enrollment
com.android.email                              | system | optional | Email
com.android.calendar                           | system | optional | Calendar
com.android.gallery3d                          | system | optional | Gallery
com.android.music                              | system | optional | Music
com.android.browser                            | system | optional | Browser
com.android.deskclock                          | system | optional | Clock / alarms
com.android.calculator2                        | system | optional | Calculator
com.android.soundrecorder                      | system | optional | Sound recorder
com.android.fmradio                            | system | optional | FM radio
com.android.quicksearchbox                     | system | optional | Search widget
com.android.printservice.recommendation        | system | optional | Print service suggestions
com.android.chrome                             | google | optional | Chrome
com.android.vending                            | google | keep     | Play Store
# ---------------- Google ----------------
com.google.android.*                           | google | caution  | Google component
com.google.android.apps.*                      | google | optional | Google app
com.google.android.gms                         | google | keep     | Play Services
com.google.android.gms.*                       | google | caution  | Play Services module
com.google.android.gsf*                        | google | keep     | Google Services Framework
com.google.android.webview                     | google | keep     | WebView
com.google.android.trichromelibrary            | google | keep     | WebView library
com.google.android.packageinstaller            | google | keep     | Package installer
com.google.android.permissioncontroller        | google | keep     | Permission controller
com.google.android.setupwizard                 | google | keep     | Setup wizard
com.google.android.inputmethod.latin           | google | keep     | Gboard
com.google.android.dialer                      | google | keep     | Phone
com.google.android.contacts                    | google | caution  | Contacts
com.google.android.apps.messaging              | google | caution  | Messages
com.google.android.documentsui                 | google | keep     | Files picker
com.google.android.providers.*                 | google | keep     | Content provider
com.google.android.networkstack*               | google | keep     | Network stack
com.google.android.ext.*                       | google | keep     | Framework extensions
com.google.android.overlay.*                   | google | keep     | Config overlay
com.google.android.modulemetadata              | google | keep     | Mainline metadata
com.google.android.captiveportallogin          | google | keep     | Wi-Fi login portal
com.google.android.photopicker                 | google | keep     | Photo picker
com.google.android.appsearch.apk               | google | keep     | AppSearch
com.google.android.sdksandbox                  | google | keep     | SDK sandbox
com.google.android.bluetooth                   | google | keep     | Bluetooth (mainline)
com.google.android.wifi.*                      | google | keep     | Wi-Fi (mainline)
com.google.android.uwb.*                       | google | keep     | UWB (mainline)
com.google.android.connectivity.resources      | google | keep     | Connectivity resources
com.google.android.safetycenter.resources      | google | keep     | Safety center resources
com.google.android.rkpdapp                     | google | keep     | Key provisioning
com.google.android.cellbroadcast*              | google | caution  | Emergency alerts
com.google.android.adservices.api              | google | caution  | Privacy sandbox (ads API)
com.google.android.ondevicepersonalization.services | google | caution | On-device personalization
com.google.android.federatedcompute            | google | caution  | Federated compute
com.google.android.configupdater               | google | caution  | Config updater
com.google.android.health.connect.*            | google | caution  | Health Connect
com.google.android.ims                         | google | caution  | Carrier services (RCS)
com.google.android.as                          | google | caution  | Android System Intelligence
com.google.android.as.oss                      | google | caution  | Private Compute Services
com.google.android.partnersetup                | google | caution  | Partner setup
com.google.android.onetimeinitializer          | google | caution  | One-time init
com.google.android.contactkeys                 | google | caution  | Contact keys
com.google.android.gms.location.history        | google | caution  | Location history
com.google.android.gms.supervision             | google | caution  | Family Link
com.google.android.apps.turbo                  | google | caution  | Device Health (battery)
com.google.android.apps.work.oobconfig         | google | caution  | Work setup
com.google.android.apps.nexuslauncher          | google | keep     | Pixel launcher
com.google.android.apps.wallpaper              | google | caution  | Wallpapers
com.google.android.googlequicksearchbox        | google | optional | Google app (Search)
com.google.android.tts                         | google | optional | Speech services
com.google.android.feedback                    | google | safe     | Feedback agent
com.google.android.youtube                     | google | optional | YouTube
com.google.android.apps.youtube.music          | google | optional | YouTube Music
com.google.android.apps.youtube.music.setupwizard | google | safe  | YouTube Music setup stub
com.google.android.apps.youtube.kids           | google | optional | YouTube Kids
com.google.android.videos                      | google | safe     | Play Movies (discontinued)
com.google.android.music                       | google | safe     | Play Music (discontinued)
com.google.android.apps.podcasts               | google | safe     | Google Podcasts (discontinued)
com.google.android.apps.magazines              | google | optional | Google News
com.google.android.apps.tachyon                | google | optional | Meet (Duo)
com.google.android.apps.maps                   | google | optional | Maps
com.google.android.apps.docs                   | google | optional | Drive
com.google.android.apps.docs.editors.*         | google | optional | Docs / Sheets / Slides
com.google.android.apps.photos                 | google | optional | Photos
com.google.android.apps.photosgo               | google | optional | Gallery Go
com.google.android.apps.subscriptions.red      | google | optional | Google One
com.google.android.gm                          | google | optional | Gmail
com.google.android.calendar                    | google | optional | Calendar
com.google.android.keep                        | google | optional | Keep notes
com.google.android.deskclock                   | google | optional | Clock / alarms
com.google.android.calculator                  | google | optional | Calculator
com.google.android.apps.wellbeing              | google | optional | Digital Wellbeing
com.google.android.apps.googleassistant        | google | optional | Assistant
com.google.android.apps.bard                   | google | optional | Gemini
com.google.android.apps.labs.language.tailwind | google | optional | NotebookLM
com.google.android.apps.classroom              | google | optional | Classroom
com.google.android.apps.kids.home              | google | optional | Kids Space
com.google.android.apps.mediahome.launcher     | google | optional | Entertainment Space
com.google.android.apps.safetyhub              | google | optional | Personal Safety
com.google.android.apps.restore                | google | safe     | Restore (setup only)
com.google.android.apps.pixelmigrate           | google | safe     | Data transfer (setup only)
com.google.android.apps.nbu.files              | google | optional | Files by Google
com.google.android.apps.nbu.paisa.user         | google | optional | Google Pay (India)
com.google.android.apps.walletnfcrel           | google | optional | Google Wallet
com.google.android.apps.chromecast.app         | google | optional | Google Home
com.google.android.apps.fitness                | google | optional | Fit
com.google.android.apps.tips                   | google | safe     | Tips
com.google.android.apps.diagnosticstool        | google | safe     | Diagnostics
com.google.android.play.games                  | google | safe     | Play Games
com.google.android.projection.gearhead         | google | optional | Android Auto
com.google.android.marvin.talkback             | google | optional | TalkBack / Accessibility
com.google.android.accessibility.*             | google | optional | Accessibility
com.google.android.printservice.recommendation | google | optional | Print service suggestions
com.google.ar.core                             | google | optional | ARCore
com.google.ar.lens                             | google | optional | Lens
com.google.ambient.streaming                   | google | optional | Cross-device streaming
com.google.mainline.*                          | google | caution  | Mainline module
# ---------------- Chipset vendors ----------------
com.qualcomm.*                                 | chipset | caution | Qualcomm component
com.qti.*                                      | chipset | caution | Qualcomm component
vendor.qti.*                                   | chipset | caution | Qualcomm component
org.codeaurora.*                               | chipset | caution | Qualcomm (CAF) component
com.quicinc.*                                  | chipset | caution | Qualcomm component
com.mediatek.*                                 | chipset | caution | MediaTek component
com.mtk.*                                      | chipset | caution | MediaTek component
com.unisoc.*                                   | chipset | caution | Unisoc component
com.sprd.*                                     | chipset | caution | Unisoc component
com.dolby.*                                    | chipset | caution | Dolby audio
com.caf.fmradio                                | chipset | optional | FM radio
com.qualcomm.qti.devicestatisticsservice       | chipset | optional | Device statistics (telemetry)
com.qti.qualcomm.mstatssystemservice           | chipset | optional | Stats service (telemetry)
com.quicinc.voice.activation                   | chipset | optional | Voice activation
com.qualcomm.qti.confdialer                    | chipset | optional | Conference dialer
com.qti.confuridialer                          | chipset | optional | Conference URI dialer
com.qualcomm.embms                             | chipset | optional | LTE broadcast
com.qualcomm.qti.ridemodeaudio                 | chipset | optional | Ride mode audio
com.mediatek.duraspeed                         | chipset | optional | DuraSpeed
com.mediatek.mtklogger                         | chipset | safe    | MTK logger
com.debug.loggerui                             | chipset | safe    | MTK debug logger
# ---------------- Carriers ----------------
com.jio.*                                      | carrier | optional | Jio
com.myairtelapp                                | carrier | optional | Airtel Thanks
com.vodafone.*                                 | carrier | optional | Vodafone
com.vzw.*                                      | carrier | optional | Verizon
com.verizon.*                                  | carrier | optional | Verizon
com.motricity.verizon.*                        | carrier | optional | Verizon
com.att.*                                      | carrier | optional | AT&T
com.tmobile.*                                  | carrier | optional | T-Mobile
com.sprint.*                                   | carrier | optional | Sprint
com.orange.*                                   | carrier | optional | Orange
com.telekom.*                                  | carrier | optional | Telekom
com.telstra.*                                  | carrier | optional | Telstra
com.ironsource.appcloud.*                      | carrier | safe     | ironSource app installer
com.dti.*                                      | carrier | safe     | Digital Turbine installer
com.digitalturbine.*                           | carrier | safe     | Digital Turbine installer
# ---------------- Third-party preloads ----------------
com.facebook.*                                 | thirdparty | safe   | Facebook
com.facebook.katana                            | thirdparty | safe   | Facebook
com.facebook.orca                              | thirdparty | safe   | Messenger
com.facebook.appmanager                        | thirdparty | safe   | Facebook App Manager
com.facebook.services                          | thirdparty | safe   | Facebook Services
com.facebook.system                            | thirdparty | safe   | Facebook App Installer
com.instagram.android                          | thirdparty | optional | Instagram
com.netflix.partner.activation                 | thirdparty | safe   | Netflix activation stub
com.netflix.mediaclient                        | thirdparty | optional | Netflix
com.linkedin.android                           | thirdparty | safe   | LinkedIn
com.amazon.*                                   | thirdparty | safe   | Amazon
in.amazon.mShop.android.shopping               | thirdparty | safe   | Amazon Shopping
com.amazon.mShop.android.shopping              | thirdparty | safe   | Amazon Shopping
com.spotify.music                              | thirdparty | optional | Spotify
com.microsoft.*                                | thirdparty | optional | Microsoft app
com.booking                                    | thirdparty | safe   | Booking.com
com.king.*                                     | thirdparty | safe   | King game (Candy Crush)
com.zhiliaoapp.musically                       | thirdparty | safe   | TikTok
com.ss.android.ugc.*                           | thirdparty | safe   | TikTok
com.snapchat.android                           | thirdparty | optional | Snapchat
com.glance.*                                   | thirdparty | safe   | Glance lock-screen ads
com.inmobi.*                                   | thirdparty | safe   | InMobi ads
com.applovin.*                                 | thirdparty | safe   | AppLovin ad installer
com.ironsource.*                               | thirdparty | safe   | ironSource ad installer
com.aura.*                                     | thirdparty | safe   | Aura app installer (ads)
com.opera.preinstall                           | thirdparty | safe   | Opera preinstall stub
com.opera.*                                    | thirdparty | optional | Opera
com.finshell.fin                               | thirdparty | safe   | Finshell finance
com.eterno*                                    | thirdparty | safe   | Dailyhunt
in.mohalla.*                                   | thirdparty | safe   | ShareChat / Moj
com.phonepe.app                                | thirdparty | optional | PhonePe
com.truecaller                                 | thirdparty | optional | Truecaller
com.redteamobile.roaming                       | thirdparty | optional | Red Tea roaming
com.os.docvault                                | thirdparty | optional | DocVault
com.dts.freefireth                             | thirdparty | safe   | Free Fire (game)
com.dts.freefiremax                            | thirdparty | safe   | Free Fire MAX (game)
com.roblox.client                              | thirdparty | safe   | Roblox (game)
net.bat.store                                  | thirdparty | safe   | AHA Games store
# ---------------- Samsung ----------------
com.samsung.*                                  | oem | caution  | Samsung component
com.sec.*                                      | oem | caution  | Samsung component
com.osp.app.signin                             | oem | caution  | Samsung account
com.samsung.android.game.gamehome              | oem | safe     | Game Launcher
com.samsung.android.game.gametools             | oem | optional | Game Booster
com.samsung.android.app.spage                  | oem | safe     | Samsung Free
com.samsung.android.arzone                     | oem | safe     | AR Zone
com.samsung.android.aremoji                    | oem | safe     | AR Emoji
com.samsung.android.ardrawing                  | oem | safe     | AR Doodle
com.samsung.android.app.tips                   | oem | safe     | Tips
com.samsung.android.kidsinstaller              | oem | safe     | Kids installer
com.samsung.android.da.daagent                 | oem | safe     | Dual Messenger agent
com.samsung.android.voc                        | oem | safe     | Samsung Members
com.samsung.android.tvplus                     | oem | safe     | Samsung TV Plus
com.samsung.android.stickercenter              | oem | safe     | Sticker center
com.samsung.android.service.peoplestripe       | oem | safe     | Edge people stripe
com.samsung.android.smartswitchassistant       | oem | safe     | Smart Switch assistant
com.sec.android.app.samsungapps                | oem | optional | Galaxy Store
com.sec.android.app.sbrowser                   | oem | optional | Samsung Internet
com.sec.android.easyMover                      | oem | optional | Smart Switch
com.samsung.android.bixby.agent                | oem | optional | Bixby
com.samsung.android.bixby.wakeup               | oem | optional | Bixby wake-up
com.samsung.android.visionintelligence         | oem | optional | Bixby Vision
com.samsung.android.app.routines               | oem | optional | Modes & Routines
com.samsung.android.forest                     | oem | optional | Digital Wellbeing (Samsung)
com.samsung.android.scloud                     | oem | optional | Samsung Cloud
com.samsung.android.oneconnect                 | oem | optional | SmartThings
com.samsung.android.app.watchmanager           | oem | optional | Galaxy Wearable
com.samsung.android.app.notes                  | oem | optional | Samsung Notes
com.samsung.android.calendar                   | oem | optional | Samsung Calendar
com.samsung.android.email.provider             | oem | optional | Samsung Email
com.samsung.android.spay                       | oem | optional | Samsung Wallet
com.samsung.android.app.sharelive              | oem | optional | Quick Share
# ---------------- Xiaomi / Redmi / POCO ----------------
com.miui.*                                     | oem | caution  | MIUI / HyperOS component
com.xiaomi.*                                   | oem | caution  | Xiaomi component
com.mi.*                                       | oem | caution  | Xiaomi component
com.milink.*                                   | oem | caution  | Xiaomi cast
com.mipay.*                                    | oem | optional | Mi Pay
com.miui.analytics                             | oem | safe     | MIUI analytics
com.miui.msa.global                            | oem | safe     | MIUI system ads
com.miui.yellowpage                            | oem | safe     | Yellow pages
com.miui.bugreport                             | oem | safe     | Bug report
com.miui.hybrid                                | oem | safe     | Quick apps
com.miui.hybrid.accessory                      | oem | safe     | Quick apps accessory
com.miui.miservice                             | oem | safe     | Services & feedback
com.miui.android.fashiongallery                | oem | safe     | Wallpaper carousel
com.xiaomi.mipicks                             | oem | safe     | GetApps
com.xiaomi.glgm                                | oem | safe     | Games
com.facemoji.lite.xiaomi                       | oem | safe     | Facemoji keyboard
com.miui.videoplayer                           | oem | optional | Mi Video
com.miui.player                                | oem | optional | Mi Music
com.mi.globalbrowser                           | oem | optional | Mi Browser
com.miui.weather2                              | oem | optional | Weather
com.miui.notes                                 | oem | optional | Notes
com.miui.compass                               | oem | optional | Compass
com.miui.calculator                            | oem | optional | Calculator
com.miui.fm                                    | oem | optional | FM radio
com.miui.cleanmaster                           | oem | optional | Cleaner
com.miui.cloudservice                          | oem | optional | Xiaomi Cloud
com.xiaomi.midrop                              | oem | optional | ShareMe
com.miui.securitycenter                        | oem | keep     | Security center
com.miui.gallery                               | oem | caution  | Gallery
com.xiaomi.joyose                              | oem | caution  | Joyose (performance)
# ---------------- OPPO / Realme / OnePlus ----------------
com.heytap.*                                   | oem | caution  | HeyTap component
com.coloros.*                                  | oem | caution  | ColorOS component
com.oplus.*                                    | oem | caution  | OPlus component
com.oppo.*                                     | oem | caution  | OPPO component
com.realme.*                                   | oem | caution  | Realme component
com.nearme.*                                   | oem | caution  | OPPO component
com.oneplus.*                                  | oem | caution  | OnePlus component
net.oneplus.*                                  | oem | caution  | OnePlus component
com.realmestore.app                            | oem | safe     | Realme Store
com.realmecomm.app                             | oem | safe     | Realme Community
com.realme.link                                | oem | optional | Realme Link
com.realme.wellbeing                           | oem | optional | Realme Wellbeing
com.realme.movieshot                           | oem | optional | Movie Shot
com.heytap.usercenter                          | oem | optional | HeyTap account
com.heytap.market                              | oem | safe     | App Market
com.heytap.cloud                               | oem | optional | HeyTap Cloud
com.heytap.accessory                           | oem | optional | Accessory
com.heytap.colorfulengine                      | oem | optional | Colorful engine
com.heytap.pictorial                           | oem | safe     | Lock-screen magazine
com.heytap.music                               | oem | optional | Music
com.heytap.browser                             | oem | optional | Browser
com.heytap.mcs                                 | oem | safe     | Push messages (MCS)
com.coloros.karaoke                            | oem | safe     | Karaoke
com.coloros.backuprestore                      | oem | optional | Backup & restore
com.coloros.weather2                           | oem | optional | Weather
com.coloros.weather.service                    | oem | optional | Weather service
com.coloros.note                               | oem | optional | Notes
com.coloros.soundrecorder                      | oem | optional | Sound recorder
com.coloros.compass2                           | oem | optional | Compass
com.coloros.video                              | oem | optional | Video player
com.coloros.oshare                             | oem | optional | OShare
com.coloros.assistantscreen                    | oem | optional | Assistant screen
com.coloros.childrenSpace                      | oem | optional | Children space
com.coloros.operationManual                    | oem | safe     | User manual
com.coloros.floatassistant                     | oem | optional | Floating assistant
com.coloros.activation                         | oem | safe     | Activation stats
com.coloros.bootreg                            | oem | safe     | Boot registration
com.coloros.lockassistant                      | oem | caution  | Lock assistant
com.coloros.securepay                          | oem | optional | Secure pay
com.oplus.ocloud                               | oem | optional | Cloud
com.oplus.themestore                           | oem | optional | Theme store
com.oplus.pay                                  | oem | optional | Pay
com.oplus.games                                | oem | safe     | Game center
com.oplus.commercial                           | oem | safe     | Commercial ads
com.oplus.viewtalk                             | oem | optional | ViewTalk
com.oplus.cast                                 | oem | optional | Cast
com.oplus.statistics.rom                       | oem | safe     | Telemetry
com.oplus.olc                                  | oem | optional | OLC
com.oppo.quicksearchbox                        | oem | optional | Quick search
com.daemon.shelper                             | oem | safe     | Shelper daemon
# ---------------- vivo / iQOO ----------------
com.vivo.*                                     | oem | caution  | vivo component
com.bbk.*                                      | oem | caution  | vivo (BBK) component
com.iqoo.*                                     | oem | caution  | iQOO component
# ---------------- Huawei / Honor ----------------
com.huawei.*                                   | oem | caution  | Huawei component
com.hihonor.*                                  | oem | caution  | Honor component
com.honor.*                                    | oem | caution  | Honor component
com.hicloud.*                                  | oem | caution  | Huawei cloud
# ---------------- Lenovo / Motorola + ODMs ----------------
com.motorola.*                                 | oem | caution  | Motorola component
com.lenovo.*                                   | oem | caution  | Lenovo component
com.tblenovo.*                                 | oem | caution  | Lenovo Tab component
com.lenovotab.*                                | oem | caution  | Lenovo Tab component
com.zui.*                                      | oem | caution  | Lenovo ZUI component
com.lmsa.*                                     | oem | safe     | Lenovo Smart Assistant
com.motorola.demo                              | oem | safe     | Retail demo mode
com.tblenovo.lenovowhatsnew                    | oem | safe     | What's New
com.lenovo.loggerpannel                        | oem | safe     | Logger panel
com.tblenovo.soundrecorder                     | oem | optional | Sound recorder
com.zui.notes                                  | oem | optional | Notes
com.tblenovo.center                            | oem | optional | Lenovo Tab center
com.lenovo.lsf                                 | oem | caution  | Lenovo service framework
cn.readpad.whiteboard                          | oem | optional | Whiteboard
com.wingtech.*                                 | oem | caution  | Wingtech (ODM) component
com.wt.*                                       | oem | caution  | Wingtech (ODM) component
com.wingtech.callrecorder                      | oem | optional | Call recorder
com.huaqin.*                                   | oem | caution  | Huaqin (ODM) component
com.longcheer.*                                | oem | caution  | Longcheer (ODM) component
com.factory.*                                  | oem | caution  | Factory test menu
# ---------------- Other OEMs ----------------
com.hmdglobal.*                                | oem | caution  | Nokia / HMD component
com.evenwell.*                                 | oem | caution  | Nokia / HMD component
com.nokia.*                                    | oem | caution  | Nokia component
com.asus.*                                     | oem | caution  | ASUS component
com.sonymobile.*                               | oem | caution  | Sony component
com.sony.*                                     | oem | caution  | Sony component
com.lge.*                                      | oem | caution  | LG component
com.transsion.*                                | oem | caution  | Transsion component
com.tecno.*                                    | oem | caution  | Tecno component
com.infinix.*                                  | oem | caution  | Infinix component
com.itel.*                                     | oem | caution  | itel component
com.afmobi.*                                   | oem | caution  | Transsion component
com.talpa.*                                    | oem | caution  | Transsion component
com.nothing.*                                  | oem | caution  | Nothing component
com.zte.*                                      | oem | caution  | ZTE component
cn.nubia.*                                     | oem | caution  | Nubia component
com.tcl.*                                      | oem | caution  | TCL component
com.tct.*                                      | oem | caution  | TCL / Alcatel component
com.lava.*                                     | oem | caution  | Lava component
'@

# Keyword heuristics for prefix / unmatched system packages (first match wins).
$KeywordRisk = @(
    @{ Risk = 'keep';     Re = 'launcher|systemui|setupwizard|provision|provider|framework|keyguard|telephony|permission|packageinstaller|inputmethod|keyboard|overlay|biometric|fingerprint|faceunlock|securitycenter|\.resources?$' }
    @{ Risk = 'caution';  Re = 'camera|\.ota$|fota|updater?\b|update|service|daemon|sensor|audio|display|power|battery|thermal|\.ims|wifi|bluetooth|nfc|gps|location|modem|radio|\.sim|carrier|engineer|factory|secret|setup|oobe|backup|sync|account|security|vpn|cellbroadcast|dialer|contacts|mms|sms|telecom|clock|alarm|penservice|stylus' }
    @{ Risk = 'safe';     Re = 'demo|appstore|market|store|games?\b|gamecenter|\.ads?\b|analytics|feedback|tips|whatsnew|help|community|forum|news|feed|recommend|promo|partner|preinstall|bootreg|commercial|statistics|logger|bugreport|survey|manual' }
    @{ Risk = 'optional'; Re = 'music|video|player|karaoke|browser|weather|compass|notes?$|recorder|calculator|calendar|fmradio|\.fm$|cloud|wallet|pay\b|theme|wallpaper|wellbeing|health|scanner|mirror|cast' }
)

# Installers that mean "you installed this yourself"
$UserInstallers = @('com.android.vending', 'org.fdroid.fdroid', 'com.aurora.store', 'com.android.packageinstaller', 'com.google.android.packageinstaller', 'com.looker.droidify', 'dev.imranr.obtainium')

# =====================================================================
# Helpers
# =====================================================================
function Write-Step($m) { Write-Host "`n$m" -ForegroundColor Magenta }
function Write-Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

function Get-AdbDevices {
    $list = @()
    foreach ($line in (& adb devices -l 2>$null)) {
        if ($line -match '^(\S+)\s+(device|unauthorized|offline|recovery|sideload|bootloader|no permissions)\b(.*)$') {
            $id = $Matches[1]; $state = $Matches[2]; $rest = $Matches[3]
            $model = ''; if ($rest -match 'model:(\S+)') { $model = $Matches[1] }
            $list += [pscustomobject]@{ serial = $id; state = $state; model = $model }
        }
    }
    return , $list
}

function Resolve-Device([string]$Wanted) {
    if (-not (Get-Command adb -ErrorAction SilentlyContinue)) { Write-Fail 'adb not found in PATH. Install Android platform-tools.'; exit 2 }
    $devs = Get-AdbDevices
    for ($try = 0; $try -lt 5 -and -not ($devs | Where-Object state -eq 'device'); $try++) {
        # flaky USB / server just starting / device re-enumerating
        & adb start-server 2>$null | Out-Null
        Start-Sleep -Seconds 2
        $devs = Get-AdbDevices
    }
    if ($Wanted) {
        $d = $devs | Where-Object serial -eq $Wanted | Select-Object -First 1
        if (-not $d) { Write-Fail "Device '$Wanted' not connected."; exit 2 }
    } else {
        $ready = @($devs | Where-Object state -eq 'device')
        if ($ready.Count -gt 1) {
            Write-Fail "Several devices connected - pass -Serial <id>:"
            $ready | ForEach-Object { Write-Host "    $($_.serial)  $($_.model)" }
            exit 2
        }
        $d = if ($ready.Count -eq 1) { $ready[0] } else { $devs | Select-Object -First 1 }
        if (-not $d) { Write-Fail 'No device found. Enable USB debugging and connect the device.'; exit 2 }
    }
    if ($d.state -eq 'unauthorized') { Write-Fail 'Device unauthorized - accept the USB debugging prompt on the device, then retry.'; exit 2 }
    if ($d.state -ne 'device') { Write-Fail "Device state is '$($d.state)' - must be booted into Android."; exit 2 }
    return $d.serial
}

# =====================================================================
# Device list mode (GUI)
# =====================================================================
if ($ListDevices) {
    $devs = @()
    if (Get-Command adb -ErrorAction SilentlyContinue) { $devs = Get-AdbDevices }
    Write-Host ('@@DEVICES=' + (ConvertTo-Json -InputObject @($devs) -Compress))
    exit 0
}

Write-Host ''
Write-Host '=============================================' -ForegroundColor Yellow
Write-Host '  ANDROID BLOATWARE SCANNER v2  (Android 9-16)' -ForegroundColor Yellow
Write-Host '=============================================' -ForegroundColor Yellow

# =====================================================================
# STEP 1: device
# =====================================================================
Write-Step 'STEP 1: Connecting...'
$Serial = Resolve-Device $Serial
$AdbArgs = @('-s', $Serial)
Write-Ok "Device: $Serial"

# =====================================================================
# STEP 2: one round-trip for props + every package list
# =====================================================================
Write-Step 'STEP 2: Reading device (single adb call)...'
$remote = 'echo @@PROPS; getprop; echo @@ALL; pm list packages -u -f; echo @@USER; pm list packages --user 0; ' +
          'echo @@SYS; pm list packages -u -s; echo @@DIS; pm list packages -d --user 0; ' +
          'echo @@INST; pm list packages -i --user 0; echo @@END'
$raw = & adb @AdbArgs shell $remote 2>&1 | ForEach-Object { "$_" }

$props = @{}; $paths = @{}; $userSet = @{}; $sysSet = @{}; $disSet = @{}; $installer = @{}
$section = ''
foreach ($line in $raw) {
    $l = $line.Trim()
    if ($l -like '@@*') { $section = $l.Substring(2); continue }
    if (-not $l) { continue }
    switch ($section) {
        'PROPS' { if ($l -match '^\[([^\]]+)\]:\s*\[(.*)\]$') { $props[$Matches[1]] = $Matches[2] } }
        'ALL'   { if ($l -match '^package:(.*)=([^=\s]+)$') { $paths[$Matches[2]] = $Matches[1] } elseif ($l -match '^package:(\S+)$') { $paths[$Matches[1]] = '' } }
        'USER'  { if ($l -match '^package:(\S+)') { $userSet[$Matches[1]] = $true } }
        'SYS'   { if ($l -match '^package:(\S+)') { $sysSet[$Matches[1]] = $true } }
        'DIS'   { if ($l -match '^package:(\S+)') { $disSet[$Matches[1]] = $true } }
        'INST'  { if ($l -match '^package:(\S+)\s+installer=(\S*)') { $installer[$Matches[1]] = $Matches[2] } }
    }
}
if ($paths.Count -eq 0) { Write-Fail 'Could not read the package list:'; $raw | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" }; exit 3 }

function P($k) { if ($props.ContainsKey($k)) { $props[$k] } else { '' } }
$sdk = 0; [void][int]::TryParse((P 'ro.build.version.sdk'), [ref]$sdk)
$device = [ordered]@{
    serial       = $Serial
    serialNo     = (P 'ro.serialno')
    manufacturer = (P 'ro.product.manufacturer')
    brand        = (P 'ro.product.brand')
    model        = (P 'ro.product.model')
    codename     = (P 'ro.product.device')
    android      = (P 'ro.build.version.release')
    sdk          = $sdk
    build        = (P 'ro.build.display.id')
    type         = $(if ((P 'ro.build.characteristics') -match 'tablet') { 'tablet' } else { 'phone' })
    scannedAt    = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}
Write-Host "  $($device.manufacturer) $($device.model) ($($device.type)) | Android $($device.android) / SDK $sdk | $($device.build)" -ForegroundColor White
if ($sdk -and $sdk -lt $MinSdk) { Write-Warn "SDK $sdk is below Android 9 - results may be incomplete." }
Write-Ok "$($paths.Count) packages ($($userSet.Count) installed for user 0, $(($paths.Count - $userSet.Count)) removed/other-user)"

# =====================================================================
# STEP 3: classify
# =====================================================================
Write-Step 'STEP 3: Classifying...'
$exact = @{}; $prefixes = @()
foreach ($line in ($RulesText -split "`r?`n")) {
    $t = $line.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
    $c = $t -split '\s*\|\s*'
    $rule = @{ Category = $c[1]; Risk = $c[2]; Label = $(if ($c.Count -gt 3) { $c[3] } else { '' }) }
    if ($c[0].EndsWith('*')) { $rule.Prefix = $c[0].TrimEnd('*'); $prefixes += $rule } else { $exact[$c[0]] = $rule }
}
$prefixes = @($prefixes | Sort-Object { $_.Prefix.Length } -Descending)

function Get-KeywordRisk($name) {
    $n = $name.ToLower()
    foreach ($k in $KeywordRisk) { if ($n -match $k.Re) { return $k.Risk } }
    return $null
}

function Get-Partition($path) {
    if (-not $path) { return '' }
    if ($path -match '^/(?:system/)?(system_ext|product|vendor|odm)/') { return $Matches[1] }
    if ($path -match '^/([^/]+)/') { return $Matches[1] }
    return ''
}

$packages = foreach ($name in ($paths.Keys | Sort-Object)) {
    $path = $paths[$name]
    $isSys = $sysSet.ContainsKey($name)
    $inst = if ($installer.ContainsKey($name)) { $installer[$name] } else { '' }
    $status = if (-not $userSet.ContainsKey($name)) { 'removed' } elseif ($disSet.ContainsKey($name)) { 'disabled' } else { 'installed' }
    $byUser = (-not $isSys) -and ($UserInstallers -contains $inst)

    $how = 'exact'; $r = $exact[$name]
    if (-not $r) { $how = 'prefix'; foreach ($p in $prefixes) { if ($name.StartsWith($p.Prefix)) { $r = $p; break } } }
    if ($r) {
        $cat = $r.Category; $risk = $r.Risk; $label = $r.Label
        if ($how -eq 'prefix' -and $risk -ne 'keep') {
            $kw = Get-KeywordRisk $name
            # ad/installer families stay junk unless the name looks core-critical
            if ($kw -and ($kw -eq 'keep' -or $cat -notin @('thirdparty', 'carrier'))) { $risk = $kw }
        }
    } elseif (-not $isSys) {
        $how = 'user'; $cat = 'user'; $risk = 'optional'; $label = ''
    } else {
        $how = 'heuristic'; $cat = 'unknown'; $risk = 'caution'; $label = ''
        $kw = Get-KeywordRisk $name; if ($kw) { $risk = $kw }
    }
    # Something you installed yourself is never auto-selected
    if ($byUser -and $risk -eq 'safe') { $risk = 'optional' }
    if ($byUser -and $cat -ne 'user') { $label = ($label + ' (installed by you)').Trim() }

    [pscustomobject][ordered]@{
        name = $name; label = $label; category = $cat; risk = $risk; status = $status
        system = $isSys; updated = ($isSys -and $path -like '/data/*'); partition = (Get-Partition $path)
        installer = $inst; byUser = $byUser; match = $how; path = $path
    }
}
$packages = @($packages)

$catOrder  = @('thirdparty', 'oem', 'carrier', 'google', 'chipset', 'unknown', 'user', 'system')
$catNames  = @{ thirdparty = 'Third-party preloads'; oem = 'OEM / ODM apps'; carrier = 'Carrier apps'; google = 'Google apps'
                chipset = 'Chipset vendor services'; unknown = 'Unrecognised system packages'; user = 'Your installed apps'; system = 'Android system' }
$riskOrder = @{ safe = 0; optional = 1; caution = 2; keep = 3 }

Write-Host ''
foreach ($c in $catOrder) {
    $g = @($packages | Where-Object category -eq $c)
    if ($g.Count -eq 0) { continue }
    $s = @($g | Where-Object { $_.risk -eq 'safe' -and $_.status -ne 'removed' }).Count
    Write-Host ('  {0,-32} {1,4}   ({2} recommended)' -f $catNames[$c], $g.Count, $s)
}
$active = @($packages | Where-Object status -ne 'removed')
$recommended = @($active | Where-Object risk -eq 'safe')
Write-Ok "$($recommended.Count) recommended for removal, $(@($packages | Where-Object status -eq 'removed').Count) already removed"

# =====================================================================
# STEP 4: write outputs
# =====================================================================
Write-Step 'STEP 4: Writing results...'
$safeName = (("$($device.brand)_$($device.model)_$(if ($device.serialNo) { $device.serialNo } else { $Serial })") -replace '[^A-Za-z0-9_-]+', '-').Trim('-')
$devDir = Join-Path $OutputDir $safeName
$histDir = Join-Path $devDir 'history'
New-Item -ItemType Directory -Force $histDir | Out-Null
$devDir = (Resolve-Path $devDir).Path
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

$summary = [ordered]@{}
foreach ($c in $catOrder) { $summary[$c] = @($packages | Where-Object category -eq $c).Count }
$scan = [ordered]@{ version = 2; device = $device; deviceDir = $devDir; summary = $summary; packages = $packages }
$json = ConvertTo-Json -InputObject $scan -Depth 5
$jsonPath = Join-Path $devDir 'latest.json'
[IO.File]::WriteAllText($jsonPath, $json, $utf8)
[IO.File]::WriteAllText((Join-Path $histDir "scan_$ts.json"), $json, $utf8)
Write-Ok "Scan:   $jsonPath"

# --- Markdown report ---
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Bloatware scan - $($device.manufacturer) $($device.model)")
$md.Add('')
$md.Add("Android $($device.android) (SDK $sdk) | $($device.type) | build ``$($device.build)`` | $($device.scannedAt)")
$md.Add('')
$md.Add("Packages: **$($packages.Count)** | recommended: **$($recommended.Count)** | already removed: **$(@($packages | Where-Object status -eq 'removed').Count)**")
foreach ($c in $catOrder) {
    $g = @($packages | Where-Object category -eq $c | Sort-Object { $riskOrder[$_.risk] }, name)
    if ($g.Count -eq 0) { continue }
    $md.Add(''); $md.Add("## $($catNames[$c]) ($($g.Count))"); $md.Add('')
    $md.Add('| Package | Label | Risk | Status | Partition |'); $md.Add('|---|---|---|---|---|')
    foreach ($p in $g) { $md.Add("| ``$($p.name)`` | $($p.label) | $($p.risk) | $($p.status) | $($p.partition) |") }
}
[IO.File]::WriteAllText((Join-Path $devDir 'report.md'), ($md -join "`n"), $utf8)
Write-Ok "Report: $(Join-Path $devDir 'report.md')"

# --- Generated removal list ---
if (-not $NoScript) {
    $scriptPath = Join-Path $devDir 'auto_remove_bloatware.ps1'

    # Remember choices from the previous list: active = '<pkg>', commented = # '<pkg>'
    # (an explicit -Level starts fresh; the old list is still backed up to history\)
    $previous = @{}
    if (Test-Path $scriptPath) {
        if (-not $PSBoundParameters.ContainsKey('Level')) { foreach ($line in (Get-Content $scriptPath)) {
            if ($line -match "^\s*'([\w.]+)'") { $previous[$Matches[1]] = $true }
            elseif ($line -match "^\s*#\s*'([\w.]+)'") { $previous[$Matches[1]] = $false }
        } }
        Copy-Item $scriptPath (Join-Path $histDir "auto_remove_bloatware_$ts.ps1")
    }

    $remover = (Resolve-Path (Join-Path $PSScriptRoot 'remover.ps1')).Path
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add('# =====================================================================')
    $out.Add('# Auto-generated debloat list - review before running!')
    $out.Add("# Device : $($device.manufacturer) $($device.model) | Android $($device.android) (SDK $sdk) | $($device.type)")
    $out.Add("# Scanned: $($device.scannedAt) | $($packages.Count) packages | level: $Level")
    $out.Add('# [keep] lines are core OS - uncommenting them can break boot/UI.')
    $out.Add('#')
    $out.Add("# Active lines are removed. Add/remove a leading '#' to change that.")
    $out.Add('# Add ANY other package as a new line:  ''com.example.app''')
    $out.Add('#')
    $out.Add('#   .\auto_remove_bloatware.ps1 -DryRun          preview only')
    $out.Add('#   .\auto_remove_bloatware.ps1                  uninstall (permanent where possible)')
    $out.Add('#   .\auto_remove_bloatware.ps1 -Mode Disable    disable instead of uninstall')
    $out.Add('#   .\auto_remove_bloatware.ps1 -Mode Restore    bring everything below back')
    $out.Add('# =====================================================================')
    $out.Add('param(')
    $out.Add("    [ValidateSet('Uninstall', 'Disable', 'Restore')][string]`$Mode = 'Uninstall',")
    $out.Add('    [switch]$DryRun,')
    $out.Add('    [string]$Serial')
    $out.Add(')')
    $out.Add('')
    $out.Add('$packages = @(')
    $maxRisk = @{ Recommended = 0; Aggressive = 1; Maximum = 2 }[$Level]
    $nOn = 0
    foreach ($c in $catOrder) {
        $g = @($active | Where-Object { $_.category -eq $c } | Sort-Object { $riskOrder[$_.risk] }, name)
        if ($g.Count -eq 0) { continue }
        $out.Add('')
        $out.Add("    # ---- $($catNames[$c]) ($($g.Count)) ----")
        foreach ($p in $g) {
            $on = if ($previous.ContainsKey($p.name)) { $previous[$p.name] }
                  elseif ($p.byUser -or $p.category -eq 'user' -or $p.risk -eq 'keep') { $false }
                  else { $riskOrder[$p.risk] -le $maxRisk }
            if ($on) { $nOn++ }
            $entry = ("'" + $p.name + "'").PadRight(58)
            $out.Add(('    {0}{1} # [{2}] {3}' -f $(if ($on) { '' } else { '# ' }), $entry, $p.risk, $p.label).TrimEnd())
        }
    }
    $out.Add(')')
    $out.Add('')
    $out.Add("`$remover = '$remover'")
    $out.Add("if (-not (Test-Path `$remover)) { `$remover = Join-Path `$PSScriptRoot '..\..\scripts\remover.ps1' }")
    $out.Add('& $remover -Packages $packages -Mode $Mode -DryRun:$DryRun -Serial $Serial')
    $out.Add('exit $LASTEXITCODE')
    [IO.File]::WriteAllText($scriptPath, ($out -join "`r`n"), $utf8Bom)
    Write-Ok "Script: $scriptPath ($nOn active)"
    Write-Warn "Review it, then preview with:  & '$scriptPath' -DryRun"
}

Write-Host "@@SCAN_JSON=$jsonPath"
Write-Host ''
Write-Host '=============================================' -ForegroundColor Yellow
Write-Host '  SCAN COMPLETE' -ForegroundColor Yellow
Write-Host '=============================================' -ForegroundColor Yellow
