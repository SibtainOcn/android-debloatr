#!/system/bin/sh
# =====================================================================
#  debloat.sh - on-device remover, no root, no PC (Android 9 - 16)
# =====================================================================
#  Runs ON the phone with shell (adb-level) rights, through either:
#    Shizuku + Termux :  sh rish -c 'sh /sdcard/Download/debloat.sh ...'
#    a PC             :  adb push debloat.sh /data/local/tmp/
#                        adb shell sh /data/local/tmp/debloat.sh ...
#
#  Same strategy as remover.ps1:
#    user app            pm uninstall            -> gone for good
#    updated system app  pm uninstall + --user 0 -> removed for you
#    system app          pm uninstall --user 0   -> removed for you
#  Restore = pm install-existing --user 0 + pm enable.
#  Nothing is blocked; core packages only print a warning.
# =====================================================================

usage() {
    cat <<'EOF'
Usage: sh debloat.sh <command> [options] [package ...]

Commands
  uninstall     remove packages (permanent where possible)
  disable       freeze packages (APK and data stay)
  restore       bring back removed or disabled packages
  status        show the state of the given packages
                (no packages: list every package with its state)

Options
  -f, --file <file>   read packages from a file (one per line, # = comment)
  -n, --dry-run       show the plan, change nothing
  -k, --keep-data     uninstall with -k (keeps data, faster restore)
  -h, --help          this help

Examples
  sh debloat.sh uninstall -n -f /sdcard/Download/debloat-list.txt
  sh debloat.sh uninstall com.facebook.appmanager com.facebook.services
  sh debloat.sh restore com.android.chrome
  sh debloat.sh status
EOF
}

MODE=""; DRY=0; KEEP=""; LIST=""; PKGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        uninstall|disable|restore|status) MODE="$1" ;;
        -n|--dry-run) DRY=1 ;;
        -k|--keep-data) KEEP="-k " ;;
        -f|--file) shift; LIST="$1" ;;
        -h|--help|help) usage; exit 0 ;;
        -*) echo "Unknown option: $1"; usage; exit 2 ;;
        *) PKGS="$PKGS $1" ;;
    esac
    shift
done
[ -z "$MODE" ] && { usage; exit 2; }

if [ -n "$LIST" ]; then
    [ -r "$LIST" ] || { echo "[FAIL] Cannot read $LIST"; exit 2; }
    PKGS="$PKGS $(sed -e 's/#.*//' -e "s/[',;\"]/ /g" "$LIST")"
fi

# ---------------------------------------------------------------------
# Device state (one dump per list, re-read after changes)
# ---------------------------------------------------------------------
# Each list is kept as " pkg1 pkg2 ... " so membership is a fast in-shell match.
names() { sed 's/^package://' | tr '\n' ' '; }
load_state() {
    ALL=" $(pm list packages -u 2>/dev/null | names) "
    USR=" $(pm list packages --user 0 2>/dev/null | names) "
    SYS=" $(pm list packages -s -u 2>/dev/null | names) "
    DIS=" $(pm list packages -d --user 0 2>/dev/null | names) "
    # installed APKs living on /data (user apps and updated system apps)
    DATA=" $(pm list packages --user 0 -f 2>/dev/null | sed -n 's#^package:/data/.*=\([^=]*\)$#\1#p' | tr '\n' ' ') "
}
inset() { case "$1" in *" $2 "*) return 0 ;; esac; return 1; }
# set KD (user / updated-system / system) and ST (installed / disabled / removed / not-on-device)
kind_of() {
    if ! inset "$SYS" "$1"; then KD="user"
    elif inset "$DATA" "$1"; then KD="updated-system"
    else KD="system"; fi
}
state_of() {
    if ! inset "$ALL" "$1"; then ST="not-on-device"
    elif ! inset "$USR" "$1"; then ST="removed"
    elif inset "$DIS" "$1"; then ST="disabled"
    else ST="installed"; fi
}
count() { echo $1 | wc -w; }

load_state
[ "$(count "$ALL")" -gt 0 ] || { echo "[FAIL] pm did not answer - run this with shell rights (adb shell or Shizuku rish)"; exit 3; }

HOME_PKG="$(cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME 2>/dev/null | tail -n 1)"
HOME_PKG="${HOME_PKG%%/*}"
IME_PKG="$(settings get secure default_input_method 2>/dev/null)"
IME_PKG="${IME_PKG%%/*}"

# ---------------------------------------------------------------------
# status
# ---------------------------------------------------------------------
if [ "$MODE" = "status" ]; then
    [ -z "$(echo $PKGS)" ] && PKGS="$(echo $ALL | tr ' ' '\n' | sort)"
    for p in $PKGS; do
        state_of "$p"; kind_of "$p"
        printf '%-14s %-15s %s\n' "$ST" "$KD" "$p"
    done
    echo "Total: $(count "$ALL") | installed for user 0: $(count "$USR") | disabled: $(count "$DIS")"
    exit 0
fi

[ -z "$(echo $PKGS)" ] && { echo "[FAIL] No packages given (use names or -f <file>)"; exit 2; }

# ---------------------------------------------------------------------
# plan + run
# ---------------------------------------------------------------------
echo "=== $MODE$( [ $DRY -eq 1 ] && echo ' (DRY RUN)') ==="
TODO=""; SKIPPED=0; i=0
for p in $PKGS; do
    case "$p" in *[!A-Za-z0-9._]*|.*|*..*) echo "  [WARN] invalid package name ignored: $p"; continue ;; esac
    state_of "$p"; kind_of "$p"; st="$ST"; k="$KD"; skip=""
    case "$MODE" in
        uninstall)
            [ "$st" = "not-on-device" ] && skip="not on device"
            [ "$st" = "removed" ] && skip="already removed" ;;
        disable)
            [ "$st" = "not-on-device" ] && skip="not on device"
            [ "$st" = "removed" ] && skip="removed (restore first)"
            [ "$st" = "disabled" ] && skip="already disabled" ;;
        restore)
            [ "$st" = "not-on-device" ] && skip="APK not on device - reinstall from a store"
            [ "$st" = "installed" ] && skip="already installed" ;;
    esac
    if [ -n "$skip" ]; then
        printf '  SKIP       %-50s %s\n' "$p" "$skip"; SKIPPED=$((SKIPPED + 1)); continue
    fi
    if [ "$MODE" != "restore" ]; then
        case "$p" in
            android|com.android.systemui|com.android.settings|com.android.phone|com.android.shell|com.google.android.gms|com.google.android.gsf|*packageinstaller|*permissioncontroller|com.android.providers.*)
                echo "  [WARN] $p is core OS - removal may break boot/UI" ;;
        esac
        [ "$p" = "$HOME_PKG" ] && echo "  [WARN] $p is your CURRENT LAUNCHER - set another one first"
        [ "$p" = "$IME_PKG" ] && echo "  [WARN] $p is your CURRENT KEYBOARD - switch keyboard first"
    fi
    if [ $DRY -eq 1 ]; then
        printf '  PLAN       %-50s %s\n' "$p" "$k"
    fi
    TODO="$TODO $p"
done

if [ $DRY -eq 1 ]; then
    echo "DRY RUN: $(echo $TODO | wc -w) to process, $SKIPPED skipped. Nothing was changed."
    exit 0
fi

total=$(echo $TODO | wc -w)
for p in $TODO; do
    i=$((i + 1)); echo "[$i/$total] $p"
    case "$MODE" in
        uninstall)
            kind_of "$p"
            case "$KD" in
                user)
                    r="$(pm uninstall $KEEP$p 2>&1)"; echo "    $r"
                    case "$r" in *Success*) ;; *) echo "    $(pm uninstall $KEEP--user 0 $p 2>&1)" ;; esac ;;
                updated-system)
                    echo "    $(pm uninstall $p 2>&1)"
                    echo "    $(pm uninstall $KEEP--user 0 $p 2>&1)" ;;
                *)
                    echo "    $(pm uninstall $KEEP--user 0 $p 2>&1)" ;;
            esac ;;
        disable) echo "    $(pm disable-user --user 0 $p 2>&1)" ;;
        restore)
            inset "$USR" "$p" || echo "    $(pm install-existing --user 0 $p 2>&1)"
            echo "    $(pm enable --user 0 $p 2>&1)" ;;
    esac
done

# ---------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------
load_state
OK=0; FAIL=0
echo ""
for p in $TODO; do
    state_of "$p"; st="$ST"; res="FAILED"
    case "$MODE:$st" in
        uninstall:not-on-device) res="PERMANENT" ;;
        uninstall:removed) res="REMOVED" ;;
        disable:disabled) res="DISABLED" ;;
        restore:installed) res="RESTORED" ;;
    esac
    [ "$res" = "FAILED" ] && FAIL=$((FAIL + 1)) || OK=$((OK + 1))
    printf '  %-10s %-50s %s\n' "$res" "$p" "now: $st"
done
echo ""
echo "DONE ($MODE): ok=$OK failed=$FAIL skipped=$SKIPPED"
[ $FAIL -eq 0 ]
