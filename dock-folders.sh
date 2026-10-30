#!/bin/bash
# dock-folders — Generate .app wrappers for folders so custom icons show in the macOS Dock
# Each generated app shows a native popup menu with the folder's contents when clicked.
#
# Usage:
#   ./dock-folders.sh /path/to/folder1 [/path/to/folder2 ...]
#   ./dock-folders.sh --output-dir ~/MyApps /path/to/folder
#   ./dock-folders.sh --all /path/to/parent-directory
#   ./dock-folders.sh --bg emoji --gradient --all /path/to/parent-directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT_DIR="$SCRIPT_DIR/build"
CONF_FILE="$SCRIPT_DIR/dock-colours.conf"
OUTPUT_DIR=""
ALL_MODE=false
BG_MODE="tag"
GRADIENT=false
FOLDERS=()

# ─── Argument parsing ───────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] FOLDER [FOLDER ...]

Generate .app wrappers for folders so their custom icons show in the macOS Dock.

Options:
  --output-dir DIR   Where to place generated .app bundles
                     (default: build/ next to this script)
  --all DIR          Process all subdirectories within DIR
  --bg MODE          Background behind a folder's emoji icon:
                       tag          colour of the folder's Finder tag (default)
                       grey         plain grey, as in earlier versions
                       emoji        main colour of the emoji itself
                       interactive  ask for a colour per folder and save it
                       saved        use colours saved by interactive mode
                     Folders without a saved colour, or without a tag, fall
                     back to the tag colour, then grey.
  --gradient         Draw the background as a light-to-dark gradient
                     (in interactive mode, this is the default answer)
  -h, --help         Show this help

Saved colours live in: $CONF_FILE

Examples:
  $(basename "$0") ~/Documents/dock-folders/coding
  $(basename "$0") --all ~/Documents/dock-folders
  $(basename "$0") --bg tag --gradient --all ~/Documents/dock-folders
  $(basename "$0") --bg interactive --all ~/Documents/dock-folders
  $(basename "$0") --output-dir ~/Desktop ~/Documents/my-folder
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --all)
            ALL_MODE=true
            shift
            ;;
        --bg)
            if [[ $# -lt 2 ]]; then
                echo "Error: --bg needs a mode (tag, grey, emoji, interactive, saved)"
                exit 1
            fi
            BG_MODE="$2"
            shift 2
            ;;
        --gradient)
            GRADIENT=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            FOLDERS+=("$1")
            shift
            ;;
    esac
done

case "$BG_MODE" in
    tag|grey|emoji|interactive|saved) ;;
    *)
        echo "Error: unknown --bg mode '$BG_MODE' (use tag, grey, emoji, interactive or saved)"
        exit 1
        ;;
esac

# In --all mode, the single argument is the parent directory
if $ALL_MODE; then
    if [[ ${#FOLDERS[@]} -ne 1 ]]; then
        echo "Error: --all requires exactly one directory argument"
        exit 1
    fi
    PARENT_DIR="${FOLDERS[0]}"
    if [[ ! -d "$PARENT_DIR" ]]; then
        echo "Error: '$PARENT_DIR' is not a directory"
        exit 1
    fi
    FOLDERS=()
    while IFS= read -r -d '' dir; do
        FOLDERS+=("$dir")
    done < <(find "$PARENT_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | sort -z)
fi

if [[ ${#FOLDERS[@]} -eq 0 ]]; then
    echo "Error: No folders specified. Use -h for help."
    exit 1
fi

OUTPUT_DIR="${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR"

# ─── Folder metadata ────────────────────────────────────────────────────────────
# Prints the folder's "Customize Folder" emoji, if it has one
folder_emoji() {
    local xattr_data
    xattr_data=$(xattr -p com.apple.icon.folder#S "$1" 2>/dev/null) || true
    if [[ -n "$xattr_data" ]]; then
        # Parse emoji from JSON like {"emoji":"👨‍💻"}
        echo "$xattr_data" | python3 -c "import sys,json; print(json.load(sys.stdin).get('emoji',''))" 2>/dev/null || true
    fi
}

# Prints the folder's Finder tag colour as a number (1 grey, 2 green, 3 purple,
# 4 blue, 5 yellow, 6 red, 7 orange), or nothing if it has no coloured tag.
# Finder stores tags as a binary plist of strings like "Blue\n4".
tag_colour_number() {
    local hex num=""
    hex=$(xattr -px com.apple.metadata:_kMDItemUserTags "$1" 2>/dev/null) || true
    if [[ -n "$hex" ]]; then
        num=$(printf '%s' "$hex" | xxd -r -p | python3 -c '
import sys, plistlib
for tag in plistlib.loads(sys.stdin.buffer.read()):
    name, _, colour = tag.rpartition("\n")
    if name and colour in ("1", "2", "3", "4", "5", "6", "7"):
        print(colour)
        break
' 2>/dev/null) || true
    fi
    # Fall back to the older single Finder label (needs Spotlight indexing)
    if [[ -z "$num" ]]; then
        num=$(mdls -raw -name kMDItemFSLabel "$1" 2>/dev/null) || true
    fi
    case "$num" in
        [1-7]) echo "$num" ;;
    esac
}

tag_colour_name() {
    case "$1" in
        1) echo "Grey" ;;
        2) echo "Green" ;;
        3) echo "Purple" ;;
        4) echo "Blue" ;;
        5) echo "Yellow" ;;
        6) echo "Red" ;;
        7) echo "Orange" ;;
    esac
}

# Matching macOS system colours, so the Dock icon matches Finder's tag dot
tag_colour_selector() {
    case "$1" in
        1) echo "systemGrayColor" ;;
        2) echo "systemGreenColor" ;;
        3) echo "systemPurpleColor" ;;
        4) echo "systemBlueColor" ;;
        5) echo "systemYellowColor" ;;
        6) echo "systemRedColor" ;;
        7) echo "systemOrangeColor" ;;
    esac
}

# Turns "#3a7bd5", "3A7BD5" or "#37d" into "#3A7BD5"; fails on anything else
normalise_hex() {
    local hex="${1#\#}"
    if [[ "$hex" =~ ^[0-9A-Fa-f]{3}$ ]]; then
        hex="${hex:0:1}${hex:0:1}${hex:1:1}${hex:1:1}${hex:2:1}${hex:2:1}"
    fi
    [[ "$hex" =~ ^[0-9A-Fa-f]{6}$ ]] || return 1
    echo "#$(echo "$hex" | tr '[:lower:]' '[:upper:]')"
}

# ─── Saved colours ──────────────────────────────────────────────────────────────
# dock-colours.conf has one line per folder name: NAME=VALUE STYLE
# where VALUE is #RRGGBB, tag, emoji or grey, and STYLE is gradient or flat.

# Prints "VALUE STYLE" for a folder name, or fails if it isn't saved
conf_lookup() {
    local line
    [[ -f "$CONF_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "${line%=*}" == "$1" ]]; then
            echo "${line##*=}"
            return 0
        fi
    done < "$CONF_FILE"
    return 1
}

# Saves (or replaces) a folder's line in the conf file
conf_save() {
    local name="$1" value="$2" style="$3" line
    local tmp="$CONF_FILE.tmp"
    {
        if [[ -f "$CONF_FILE" ]]; then
            while IFS= read -r line || [[ -n "$line" ]]; do
                [[ "${line%=*}" == "$name" ]] || printf '%s\n' "$line"
            done < "$CONF_FILE"
        else
            echo "# Dock folder background colours, written by dock-folders.sh --bg interactive"
            echo "# NAME=VALUE STYLE  (VALUE: #RRGGBB, tag, emoji or grey; STYLE: gradient or flat)"
        fi
        printf '%s=%s %s\n' "$name" "$value" "$style"
    } > "$tmp"
    mv "$tmp" "$CONF_FILE"
}

# ─── Background colour ──────────────────────────────────────────────────────────
# Sets BG_KIND (grey, system, rgb or emoji), BG_SELECTOR / BG_R BG_G BG_B,
# BG_GRADIENT and BG_DESC from a value (#RRGGBB, tag, emoji or grey).
set_background() {
    local folder="$1" value="$2" gradient="$3" num
    BG_GRADIENT="$gradient"
    case "$value" in
        tag)
            num=$(tag_colour_number "$folder")
            if [[ -n "$num" ]]; then
                BG_KIND="system"
                BG_SELECTOR=$(tag_colour_selector "$num")
                BG_DESC="$(tag_colour_name "$num") (Finder tag)"
            else
                BG_KIND="grey"
                BG_DESC="grey (no Finder tag)"
            fi
            ;;
        emoji)
            BG_KIND="emoji"
            BG_DESC="emoji colour"
            ;;
        grey)
            BG_KIND="grey"
            BG_DESC="grey"
            ;;
        \#*)
            BG_KIND="rgb"
            BG_R=$((16#${value:1:2}))
            BG_G=$((16#${value:3:2}))
            BG_B=$((16#${value:5:2}))
            BG_DESC="$value"
            ;;
    esac
    if $gradient; then
        BG_DESC="$BG_DESC, gradient"
    fi
}

# Asks for one folder's colour and gradient, then saves the answer
ask_background() {
    local folder="$1" name="$2" emoji="$3"
    local saved value style answer num tag_desc="no Finder tag"
    local default_style="flat" gradient_hint="[y/N]"
    if $GRADIENT; then
        default_style="gradient"
        gradient_hint="[Y/n]"
    fi
    num=$(tag_colour_number "$folder")
    [[ -n "$num" ]] && tag_desc="tag: $(tag_colour_name "$num")"

    echo ""
    echo "$emoji $name ($tag_desc)"

    if saved=$(conf_lookup "$name"); then
        printf '  Saved: %s, %s. Use it? [Y/n]: ' "${saved% *}" "${saved##* }"
        read -r answer || { echo; echo "Cancelled."; exit 1; }
        case "$answer" in
            [Nn]*) ;;
            *) return 0 ;;
        esac
    fi

    while true; do
        printf '  Colour (#hex, or tag / emoji / grey) [Enter = tag]: '
        read -r answer || { echo; echo "Cancelled."; exit 1; }
        case "$answer" in
            ""|tag) value="tag"; break ;;
            emoji|grey) value="$answer"; break ;;
        esac
        if value=$(normalise_hex "$answer"); then
            break
        fi
        echo "  ⚠ '$answer' isn't a hex colour — try something like #3A7BD5"
    done

    printf '  Gradient? %s: ' "$gradient_hint"
    read -r answer || { echo; echo "Cancelled."; exit 1; }
    case "$answer" in
        [Yy]*) style="gradient" ;;
        [Nn]*) style="flat" ;;
        *) style="$default_style" ;;
    esac

    conf_save "$name" "$value" "$style"
    echo "  💾 Saved: $value, $style"
}

# ─── Icon extraction ────────────────────────────────────────────────────────────
# Extracts the folder's rendered icon (including custom emoji + color) as .icns
# Uses the BG_* settings from set_background for emoji icons.
create_icns() {
    local folder_path="$1"
    local icns_path="$2"
    local png_path="${icns_path%.icns}.png"
    local iconset_dir="${icns_path%.icns}.iconset"

    # Check for "Customize Folder" emoji icon (stored as JSON xattr)
    local emoji
    emoji=$(folder_emoji "$folder_path")

    # Step 1: Render the folder icon as 1024x1024 PNG via AppleScript ObjC bridge
    if [[ -n "$emoji" ]]; then
        # Background colour, as AppleScript, from the BG_* settings
        local bg_colour_code
        case "$BG_KIND" in
            system)
                bg_colour_code="set bgColor to current application's NSColor's ${BG_SELECTOR}()" ;;
            rgb)
                bg_colour_code="set bgColor to current application's NSColor's colorWithSRGBRed:(${BG_R} / 255) green:(${BG_G} / 255) blue:(${BG_B} / 255) alpha:1.0" ;;
            emoji)
                bg_colour_code="set bgColor to my emojiColour(emojiStr)" ;;
            *)
                bg_colour_code="set bgColor to current application's NSColor's colorWithCalibratedRed:0.455 green:0.455 blue:0.471 alpha:1.0" ;;
        esac

        # Render emoji on a coloured background (macOS adds its own squircle mask)
        osascript <<ICONSCRIPT >/dev/null 2>&1
use framework "AppKit"
use framework "Foundation"
use scripting additions

-- Main colour of the emoji: draw it small and average its pixels, weighting
-- vivid ones most so black outlines and white highlights don't wash it out.
-- Shifted darker (or lighter, for dark emoji) so the emoji stands out on it.
on emojiColour(emojiStr)
    set sp to 32
    set smallRep to (current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:sp pixelsHigh:sp bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSCalibratedRGBColorSpace) bytesPerRow:0 bitsPerPixel:0)
    current application's NSGraphicsContext's setCurrentContext:(current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:smallRep)
    set smallFont to current application's NSFont's systemFontOfSize:(sp * 0.6)
    set smallAttrs to current application's NSDictionary's dictionaryWithObjects:{smallFont} forKeys:{current application's NSFontAttributeName}
    set smallStr to (current application's NSAttributedString's alloc()'s initWithString:emojiStr attributes:smallAttrs)
    set smallSize to smallStr's |size|()
    smallStr's drawAtPoint:{x:((sp - (smallSize's width)) / 2), y:((sp - (smallSize's height)) / 2)}
    current application's NSGraphicsContext's setCurrentContext:(missing value)

    set {wSum, rSum, gSum, bSum} to {0, 0, 0, 0}
    set {nPlain, rPlain, gPlain, bPlain} to {0, 0, 0, 0}
    repeat with x from 0 to sp - 1
        repeat with y from 0 to sp - 1
            set c to (smallRep's colorAtX:x y:y)
            if (c's alphaComponent()) > 0.9 then
                set r to (c's redComponent()) as real
                set g to (c's greenComponent()) as real
                set b to (c's blueComponent()) as real
                set hi to r
                if g > hi then set hi to g
                if b > hi then set hi to b
                set lo to r
                if g < lo then set lo to g
                if b < lo then set lo to b
                set {nPlain, rPlain, gPlain, bPlain} to {nPlain + 1, rPlain + r, gPlain + g, bPlain + b}
                -- Weight by chroma, so near-black and near-white pixels barely count
                set w to (hi - lo) * (hi - lo)
                set {wSum, rSum, gSum, bSum} to {wSum + w, rSum + r * w, gSum + g * w, bSum + b * w}
            end if
        end repeat
    end repeat

    if wSum > 5 then
        set {r, g, b} to {rSum / wSum, gSum / wSum, bSum / wSum}
    else if nPlain > 0 then
        -- Mostly grey/black/white emoji: plain average instead
        set {r, g, b} to {rPlain / nPlain, gPlain / nPlain, bPlain / nPlain}
    else
        return current application's NSColor's colorWithCalibratedRed:0.455 green:0.455 blue:0.471 alpha:1.0
    end if
    set avgColour to current application's NSColor's colorWithCalibratedRed:r green:g blue:b alpha:1.0
    if (0.299 * r + 0.587 * g + 0.114 * b) < 0.4 then
        return avgColour's blendedColorWithFraction:0.45 ofColor:(current application's NSColor's whiteColor())
    end if
    return avgColour's blendedColorWithFraction:0.3 ofColor:(current application's NSColor's blackColor())
end emojiColour

set px to 1024
set emojiStr to current application's NSString's stringWithString:"${emoji}"

-- Work out the colour before the big canvas becomes the drawing context
${bg_colour_code}
set bgColor to bgColor's colorUsingColorSpace:(current application's NSColorSpace's sRGBColorSpace())

-- Create canvas
set bitmapRep to (current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:px pixelsHigh:px bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSCalibratedRGBColorSpace) bytesPerRow:0 bitsPerPixel:0)

set ctx to (current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:bitmapRep)
current application's NSGraphicsContext's setCurrentContext:ctx

-- Fill the background: flat, or lighter at the top and darker at the bottom
set bgRect to {{0, 0}, {px, px}}
if ${BG_GRADIENT} then
    set topColour to bgColor's blendedColorWithFraction:0.25 ofColor:(current application's NSColor's whiteColor())
    set bottomColour to bgColor's blendedColorWithFraction:0.2 ofColor:(current application's NSColor's blackColor())
    set bgGradient to current application's NSGradient's alloc()'s initWithStartingColor:bottomColour endingColor:topColour
    bgGradient's drawInRect:bgRect angle:90
else
    set bgPath to current application's NSBezierPath's bezierPathWithRect:bgRect
    bgColor's setFill()
    bgPath's fill()
end if

-- Draw emoji large and centered
set emojiSize to 620
set emojiFont to current application's NSFont's systemFontOfSize:emojiSize
set emojiAttrs to current application's NSDictionary's dictionaryWithObjects:{emojiFont} forKeys:{current application's NSFontAttributeName}
set attrStr to (current application's NSAttributedString's alloc()'s initWithString:emojiStr attributes:emojiAttrs)
set strSize to attrStr's |size|()
set strW to strSize's width
set strH to strSize's height
set drawX to ((px - strW) / 2)
set drawY to ((px - strH) / 2)
attrStr's drawAtPoint:{x:drawX, y:drawY}

current application's NSGraphicsContext's setCurrentContext:(missing value)

set pngData to bitmapRep's representationUsingType:4 |properties|:(missing value)
set outURL to current application's NSURL's fileURLWithPath:"${png_path}"
pngData's writeToURL:outURL options:0 |error|:(missing value)
ICONSCRIPT
    else
        # No custom emoji — use NSWorkspace's standard icon
        osascript <<ICONSCRIPT >/dev/null 2>&1
use framework "AppKit"
use framework "Foundation"
use scripting additions

set ws to current application's NSWorkspace's sharedWorkspace()
set theIcon to ws's iconForFile:"${folder_path}"
theIcon's setSize:{width:1024, height:1024}

set bitmapRep to (current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:1024 pixelsHigh:1024 bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSCalibratedRGBColorSpace) bytesPerRow:0 bitsPerPixel:0)

set ctx to (current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:bitmapRep)
current application's NSGraphicsContext's setCurrentContext:ctx
theIcon's drawInRect:{origin:{x:0, y:0}, |size|:{width:1024, height:1024}}
current application's NSGraphicsContext's setCurrentContext:(missing value)

set pngData to bitmapRep's representationUsingType:4 |properties|:(missing value)
set outURL to current application's NSURL's fileURLWithPath:"${png_path}"
pngData's writeToURL:outURL options:0 |error|:(missing value)
ICONSCRIPT
    fi

    if [[ ! -f "$png_path" || ! -s "$png_path" ]]; then
        return 1
    fi

    # Step 2: Create iconset with all required sizes via sips
    mkdir -p "$iconset_dir"
    sips -z 16 16     "$png_path" --out "$iconset_dir/icon_16x16.png"      >/dev/null 2>&1
    sips -z 32 32     "$png_path" --out "$iconset_dir/icon_16x16@2x.png"   >/dev/null 2>&1
    sips -z 32 32     "$png_path" --out "$iconset_dir/icon_32x32.png"      >/dev/null 2>&1
    sips -z 64 64     "$png_path" --out "$iconset_dir/icon_32x32@2x.png"   >/dev/null 2>&1
    sips -z 128 128   "$png_path" --out "$iconset_dir/icon_128x128.png"    >/dev/null 2>&1
    sips -z 256 256   "$png_path" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$png_path" --out "$iconset_dir/icon_256x256.png"    >/dev/null 2>&1
    sips -z 512 512   "$png_path" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$png_path" --out "$iconset_dir/icon_512x512.png"    >/dev/null 2>&1
    sips -z 1024 1024 "$png_path" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null 2>&1

    # Step 3: Convert iconset to icns
    iconutil -c icns "$iconset_dir" -o "$icns_path" 2>/dev/null
    local result=$?

    # Cleanup
    rm -rf "$iconset_dir" "$png_path"
    return $result
}

# ─── AppleScript template ───────────────────────────────────────────────────────
generate_applescript() {
    local folder_path="$1"
    local folder_name="$2"

    cat <<APPLESCRIPT
use framework "AppKit"
use framework "Foundation"
use scripting additions

property NSMenu : a reference to current application's NSMenu
property NSMenuItem : a reference to current application's NSMenuItem
property NSWorkspace : a reference to current application's NSWorkspace
property NSEvent : a reference to current application's NSEvent
property NSURL : a reference to current application's NSURL
property NSImage : a reference to current application's NSImage

-- When/where the menu was last dismissed without choosing anything
property lastDismissTime : 0
property lastDismissX : 0
property lastDismissY : 0

on run
    showFolderMenu()
end run

on reopen
    -- Clicking the Dock icon while the menu is open dismisses the menu, then
    -- macOS sends a reopen for that same click. Treat that as "close" rather
    -- than opening the menu again: ignore a reopen that arrives right after a
    -- dismissal with the mouse still in the same spot (i.e. on the Dock icon).
    set mouseLoc to NSEvent's mouseLocation()
    set sinceDismiss to ((current application's NSDate's timeIntervalSinceReferenceDate()) as real) - lastDismissTime
    set dx to ((mouseLoc's x) as real) - lastDismissX
    set dy to ((mouseLoc's y) as real) - lastDismissY
    set lastDismissTime to 0
    if sinceDismiss < 1 and (dx * dx + dy * dy) < 400 then return
    showFolderMenu()
end reopen

on showFolderMenu()
    set folderPath to "$folder_path"
    
    -- Use "list folder" from Standard Additions (runs in-process, no Apple Events needed)
    try
        set folderAlias to (POSIX file folderPath) as alias
        set allNames to list folder folderAlias without invisibles
    on error errMsg number errNum
        display dialog "Cannot read folder: " & folderPath & return & return & "Error " & errNum & ": " & errMsg buttons {"OK"} default button "OK" with icon caution
        return
    end try
    
    -- Sort names alphabetically (A-Z, case-insensitive) using Cocoa
    set cocoaArray to current application's NSMutableArray's arrayWithArray:allNames
    cocoaArray's sortUsingSelector:"localizedCaseInsensitiveCompare:"
    set allNames to cocoaArray as list
    
    if (count of allNames) is 0 then
        display dialog "Folder is empty." buttons {"OK"} default button "OK"
        return
    end if
    
    -- Build NSMenu with icons
    set theMenu to NSMenu's alloc()'s initWithTitle:""
    (theMenu's setMinimumWidth:220)
    (theMenu's setAutoenablesItems:false)
    set ws to NSWorkspace's sharedWorkspace()
    
    -- Header item (folder name, non-clickable)
    set headerItem to (NSMenuItem's alloc()'s initWithTitle:"$folder_name" action:(missing value) keyEquivalent:"")
    set headerFont to current application's NSFont's boldSystemFontOfSize:13
    set headerAttrs to current application's NSDictionary's dictionaryWithObject:headerFont forKey:(current application's NSFontAttributeName)
    set headerAttrStr to (current application's NSAttributedString's alloc()'s initWithString:"$folder_name" attributes:headerAttrs)
    (headerItem's setAttributedTitle:headerAttrStr)
    (headerItem's setEnabled:false)
    (theMenu's addItem:headerItem)
    (theMenu's addItem:(NSMenuItem's separatorItem()))
    
    repeat with aName in allNames
        set itemPath to folderPath & "/" & aName
        
        -- Display name: strip .app extension for cleaner look
        set displayName to aName as text
        if displayName ends with ".app" then
            set displayName to text 1 thru -5 of displayName
        end if
        
        set menuItem to (NSMenuItem's alloc()'s initWithTitle:displayName action:(missing value) keyEquivalent:"")
        (menuItem's setEnabled:true)
        set itemIcon to (ws's iconForFile:itemPath)
        (itemIcon's setSize:{width:24, height:24})
        (menuItem's setImage:itemIcon)
        -- macOS 27+ hides menu item images by default; ask for them to be shown
        -- (1 = NSMenuItemImageVisibilityVisible). Older macOS lacks this property.
        if (menuItem's respondsToSelector:"setPreferredImageVisibility:") as boolean then
            (menuItem's setPreferredImageVisibility:1)
        end if
        (menuItem's setRepresentedObject:itemPath)
        (theMenu's addItem:menuItem)
    end repeat
    
    -- Add separator + "Show in Finder" at bottom
    (theMenu's addItem:(NSMenuItem's separatorItem()))
    set finderItem to (NSMenuItem's alloc()'s initWithTitle:"Show in Finder" action:(missing value) keyEquivalent:"")
    (finderItem's setEnabled:true)
    (finderItem's setTag:-1)
    (theMenu's addItem:finderItem)
    
    -- Position popup near the bottom of screen (Dock area)
    -- (or beside the Dock if it's on the left/right — see menuPosition below)
    set popupPoint to my menuPosition(theMenu)
    
    set wasSelected to (theMenu's popUpMenuPositioningItem:(missing value) atLocation:popupPoint inView:(missing value))
    
    if not (wasSelected as boolean) then
        set lastDismissTime to (current application's NSDate's timeIntervalSinceReferenceDate()) as real
        set dismissLoc to NSEvent's mouseLocation()
        set lastDismissX to (dismissLoc's x) as real
        set lastDismissY to (dismissLoc's y) as real
    end if
    
    if wasSelected as boolean then
        set clicked to theMenu's highlightedItem()
        if clicked is not missing value then
            set clickedTag to (clicked's tag()) as integer
            if clickedTag is -1 then
                -- "Show in Finder" via NSWorkspace (no Apple Events needed)
                set folderURL to NSURL's fileURLWithPath:folderPath
                ws's openURL:folderURL
            else
                set clickedPath to (clicked's representedObject()) as text
                set clickedURL to NSURL's fileURLWithPath:clickedPath
                ws's openURL:clickedURL
            end if
        end if
    end if
end showFolderMenu

-- Work out where to pop the menu up so it sits beside the Dock, whichever
-- edge of the screen the Dock is on. Returns the menu's top-left corner in
-- screen coordinates (origin bottom-left, as popUpMenuPositioningItem expects).
on menuPosition(theMenu)
    set gap to 8
    set mouseLoc to NSEvent's mouseLocation()
    set mouseX to (mouseLoc's x) as real
    set mouseY to (mouseLoc's y) as real

    set menuSize to theMenu's |size|()
    set menuW to (menuSize's width) as real
    set menuH to (menuSize's height) as real

    -- The Dock is on the screen the mouse is on (it was just clicked)
    set theScreen to current application's NSScreen's mainScreen()
    repeat with aScreen in (current application's NSScreen's screens() as list)
        set f to aScreen's frame()
        set fX to (item 1 of item 1 of f) as real
        set fY to (item 2 of item 1 of f) as real
        set fW to (item 1 of item 2 of f) as real
        set fH to (item 2 of item 2 of f) as real
        if mouseX ≥ fX and mouseX ≤ (fX + fW) and mouseY ≥ fY and mouseY ≤ (fY + fH) then
            set theScreen to contents of aScreen
            exit repeat
        end if
    end repeat

    set f to theScreen's frame()
    set fMinX to (item 1 of item 1 of f) as real
    set fMinY to (item 2 of item 1 of f) as real
    set fMaxX to fMinX + ((item 1 of item 2 of f) as real)

    -- visibleFrame excludes the Dock (unless it's auto-hidden)
    set vf to theScreen's visibleFrame()
    set vMinX to (item 1 of item 1 of vf) as real
    set vMinY to (item 2 of item 1 of vf) as real
    set vMaxX to vMinX + ((item 1 of item 2 of vf) as real)

    set dockPrefs to current application's NSUserDefaults's alloc()'s initWithSuiteName:"com.apple.dock"
    set dockEdge to dockPrefs's stringForKey:"orientation"
    if dockEdge is missing value then
        set dockEdge to "bottom"
    else
        set dockEdge to dockEdge as text
    end if

    -- If the Dock is auto-hidden, visibleFrame doesn't reserve its space, so
    -- fall back to an offset from the mouse (which is over the Dock icon)
    if dockEdge is "left" then
        set edgeX to vMinX
        if (edgeX - fMinX) < 10 then set edgeX to mouseX + 40
        return {edgeX + gap, mouseY + (menuH / 2)}
    else if dockEdge is "right" then
        set edgeX to vMaxX
        if (fMaxX - edgeX) < 10 then set edgeX to mouseX - 40
        return {edgeX - gap - menuW, mouseY + (menuH / 2)}
    else
        set edgeY to vMinY
        if (edgeY - fMinY) < 10 then set edgeY to mouseY + 40
        return {mouseX - (menuW / 2), edgeY + gap + menuH}
    end if
end menuPosition
APPLESCRIPT
}

# ─── Main loop ───────────────────────────────────────────────────────────────────
echo "🗂  Dock Folders Generator"
echo "   Output: $OUTPUT_DIR"
echo "   Background: $BG_MODE$($GRADIENT && echo ", gradient")"
echo ""

# Interactive mode asks about every folder up front and saves the answers,
# then builds them all from the saved colours
if [[ "$BG_MODE" == "interactive" ]]; then
    echo "🎨 Choose a background for each folder"
    for folder in "${FOLDERS[@]}"; do
        folder="$(cd "$folder" 2>/dev/null && pwd)" || continue
        emoji=$(folder_emoji "$folder")
        if [[ -z "$emoji" ]]; then
            echo ""
            echo "📁 $(basename "$folder") has no emoji — it uses Finder's own folder icon, skipping"
            continue
        fi
        ask_background "$folder" "$(basename "$folder")" "$emoji"
    done
    echo ""
    BG_MODE="saved"
fi

for folder in "${FOLDERS[@]}"; do
    # Resolve to absolute path
    folder="$(cd "$folder" 2>/dev/null && pwd)"

    if [[ ! -d "$folder" ]]; then
        echo "⚠ Skipping '$folder' — not a directory"
        continue
    fi

    folder_name="$(basename "$folder")"

    # Work out this folder's background colour
    if [[ "$BG_MODE" == "saved" ]] && saved=$(conf_lookup "$folder_name"); then
        if [[ "${saved##* }" == "gradient" ]]; then
            set_background "$folder" "${saved% *}" true
        else
            set_background "$folder" "${saved% *}" false
        fi
    elif [[ "$BG_MODE" == "saved" ]]; then
        set_background "$folder" tag "$GRADIENT"
    else
        set_background "$folder" "$BG_MODE" "$GRADIENT"
    fi
    app_name="${folder_name}.app"
    app_path="$OUTPUT_DIR/$app_name"

    echo "📁 Processing: $folder_name"

    # Quit any running copy first. The apps are stay-open background apps, so an
    # old version keeps running (invisibly) and answers Dock clicks with its old
    # code even after the bundle on disk has been replaced.
    app_exec_pattern="$(printf '%s' "/${app_name}/Contents/MacOS/applet" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
    if pkill -f "$app_exec_pattern" 2>/dev/null; then
        echo "  ⏹ Quit running copy of $app_name"
        sleep 1
    fi

    # Remove old version if it exists
    if [[ -d "$app_path" ]]; then
        rm -rf "$app_path"
    fi

    # 1. Generate AppleScript source
    tmp_script="$OUTPUT_DIR/.tmp_${folder_name}.applescript"
    generate_applescript "$folder" "$folder_name" > "$tmp_script"

    # 2. Compile to .app bundle (stay-open so it handles reopen events)
    echo "  ⚙ Compiling app..."
    osacompile -s -o "$app_path" "$tmp_script" 2>/dev/null
    rm -f "$tmp_script"

    # 3. Extract and set custom icon
    if [[ -n "$(folder_emoji "$folder")" ]]; then
        echo "  🎨 Extracting folder icon (background: $BG_DESC)..."
    else
        echo "  🎨 Extracting folder icon (no emoji — using Finder's folder icon)..."
    fi
    tmp_icns="$OUTPUT_DIR/.tmp_${folder_name}.icns"

    if create_icns "$folder" "$tmp_icns"; then
        cp "$tmp_icns" "$app_path/Contents/Resources/applet.icns"
        # Remove the asset catalog — it contains the default applet icon and
        # takes precedence over applet.icns on modern macOS
        rm -f "$app_path/Contents/Resources/Assets.car"
        echo "  ✅ Icon applied"
    else
        echo "  ⚠ Could not extract icon, using system default"
    fi
    rm -f "$tmp_icns"

    # 4. Update Info.plist with a proper bundle identifier
    bundle_id="com.dock-folders.$(echo "$folder_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$app_path/Contents/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" "$app_path/Contents/Info.plist" 2>/dev/null

    # Set a proper display name
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $folder_name" "$app_path/Contents/Info.plist" 2>/dev/null

    # Hide from CMD+Tab app switcher (agent app — no Dock bounce, no menu bar)
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$app_path/Contents/Info.plist" 2>/dev/null || true

    # Add usage descriptions so macOS can prompt for permissions
    /usr/libexec/PlistBuddy -c "Add :NSAppleEventsUsageDescription string This app needs permission to show folder contents." "$app_path/Contents/Info.plist" 2>/dev/null || true

    # 5. Ad-hoc code-sign so macOS TCC can track the app's identity
    #    Without signing, TCC silently blocks access to ~/Documents, ~/Desktop, etc.
    echo "  🔏 Code-signing..."
    xattr -cr "$app_path" 2>/dev/null
    codesign --force --sign - "$app_path" 2>&1 || echo "  ⚠ Code-signing failed (non-fatal)"

    # Touch to refresh icon cache
    touch "$app_path"

    echo "  ✅ Created: $app_path"
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done! Drag the .app files from '$OUTPUT_DIR' into your Dock."
echo ""
echo "💡 First launch: if the folder is in ~/Documents, ~/Desktop,"
echo "   or ~/Downloads, macOS may ask for permission — click Allow."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

