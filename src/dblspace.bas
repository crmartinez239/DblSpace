' dblspace.bas - Mac-style "double-tap Space to insert a period" for Windows
' Copyright (c) 2026 Christopher Martinez. MIT License - see LICENSE.txt.
'
' Build: run build.bat in the repo root (makes dist\dblspace.exe + installer),
' or from this src folder:   fbc64 -s gui -mt dblspace.bas dblspace.rc
' Result: dblspace.exe - a tray app, no console, no runtime dependencies.
' dblspace.rc embeds dblspace.ico (ON, also the .exe icon), dblspace_off.ico
' (OFF) and dblspace.manifest (DPI awareness). Keep them next to the .bas.
'
' Rule (same as macOS): when the character before the caret is a letter or
' digit (any language), or a closing quote/bracket after one, and you tap
' Space twice quickly, the two spaces become ". ".
'
' How it works
'  - A keyboard + mouse hook runs on its own high-priority thread and keeps a
'    short history of what was typed (letters, spaces, punctuation...).
'    Backspace removes from the history; clicks, arrow keys, shortcuts and
'    window switches reset it, because the caret may have moved.
'  - On a double tap the 2nd Space is held back and the main thread types
'    Backspace + ". ". Keys typed in the meantime are queued and replayed
'    after it, so nothing gets out of order.
'  - It always stays out of password fields, programs running as
'    administrator (Windows won't let us type into them) and Chinese/
'    Japanese/Korean input methods while composing. By default it also skips
'    fullscreen apps/games, terminals and code editors (macOS doesn't do it
'    there either) - these, the timing and a per-app list are in Settings.

#define _WIN32_WINNT &h0602
#include once "windows.bi"
#include once "win/shellapi.bi"
#include once "win/oleacc.bi"
#include once "win/oleauto.bi"
#include once "win/imm.bi"
#include once "win/commctrl.bi"
#inclib "comctl32"
#include once "win/commdlg.bi"
#inclib "comdlg32"
#include once "crt/string.bi"

' Max gap between the two Space presses (adjustable in Settings)
const DELAY_MIN     = 150          ' below this even fast typists miss it
const DELAY_MAX     = 1000
const DELAY_STEP    = 50
const DELAY_DEFAULT = 500

' Settings live in HKCU\Software\DblSpace
const CFG_KEY = "Software\DblSpace"

const CHECK_TIMEOUT_MS = 150       ' max wait for the password/IME check

' Built-in app categories that can be skipped (checkboxes in Settings).
' Lowercase, each wrapped in |...|.
const TERMINAL_CLASSES = "|consolewindowclass|cascadia_hosting_window_class|mintty|putty|virtualconsoleclass|"
const TERMINAL_EXES    = "|windowsterminal.exe|wt.exe|mintty.exe|putty.exe|conemu64.exe|alacritty.exe|" _
                       & "wezterm-gui.exe|"
const EDITOR_EXES      = "|code.exe|code - insiders.exe|cursor.exe|windsurf.exe|devenv.exe|sublime_text.exe|" _
                       & "idea64.exe|pycharm64.exe|webstorm64.exe|rider64.exe|clion64.exe|goland64.exe|" _
                       & "phpstorm64.exe|studio64.exe|notepad++.exe|"
const APPLIST_MAX = 4000           ' max length of the user's "|a.exe|b.exe|" list

const RUN_KEY   = "Software\Microsoft\Windows\CurrentVersion\Run"
const RUN_VALUE = "DblSpace"

const WM_TRAY       = WM_APP + 1
const WM_FLUSH      = WM_APP + 2
const IDM_EXIT      = 1003
const IDM_SETTINGS  = 1004
const IDT_TRAYRETRY = 1               ' timer: retry adding the tray icon

' Settings window controls
const IDC_GRP_TYPING = 2001
const IDC_ENABLED    = 2002
const IDC_AUTOSTART  = 2003
const IDC_SPEEDLBL   = 2004
const IDC_SLIDER     = 2005
const IDC_MINLBL     = 2006
const IDC_MAXLBL     = 2007
const IDC_CLOSERS    = 2008
const IDC_GRP_WHERE  = 2010
const IDC_MODE_ALL   = 2011
const IDC_MODE_ONLY  = 2012
const IDC_LIST       = 2013
const IDC_ADD        = 2014
const IDC_REMOVE     = 2015
const IDC_SKIPEDIT   = 2016
const IDC_SKIPTERM   = 2017
const IDC_SKIPFULL   = 2018
const IDC_NOTE       = 2019
const IDM_ADD_BROWSE = 2999           ' "Add app" menu: Browse...
const IDM_ADD_FIRST  = 3000           ' "Add app" menu: running apps

#ifndef WM_DPICHANGED
const WM_DPICHANGED = &h02E0
#endif

' Icon resource IDs - must match dblspace.rc
const IDI_ON  = 1
const IDI_OFF = 2

' What the history remembers about each typed character
const C_WORD   = 1                 ' letter or digit
const C_CLOSER = 2                 ' ) ] } " ' and curly closing quotes
const C_SPACE  = 3
const C_OTHER  = 4

const HMAX = 64                    ' history length
const QMAX = 256                   ' max keys held back during one flush

#ifndef IMC_GETOPENSTATUS
const IMC_GETOPENSTATUS = 5
#endif
#ifndef IMC_GETCONVERSIONMODE
const IMC_GETCONVERSIONMODE = 1
#endif

' Our own copies of two Win32 structs. This sidesteps how the FreeBASIC
' headers rename fields that clash with BASIC keywords (type, time, input).
type KbHookData                    ' = KBDLLHOOKSTRUCT
    vkCode   as DWORD
    scanCode as DWORD
    flags    as DWORD
    tstamp   as DWORD
    extra    as ULONG_PTR
end type

type KbInput                       ' = INPUT, keyboard member of the union
    itype    as DWORD
    #ifdef __FB_64BIT__
    pad0     as DWORD              ' union is 8-byte aligned on x64
    #endif
    wVk      as WORD
    wScan    as WORD
    dwFlags  as DWORD
    tstamp   as DWORD
    extra    as ULONG_PTR
    reserved(0 to 1) as DWORD      ' pad to sizeof(INPUT): 28 (x86) / 40 (x64)
end type

type QItem                         ' a key held back while a period is pending
    isPeriod as boolean            ' true = the swallowed 2nd Space
    isUp     as boolean
    vk       as DWORD
    scan     as DWORD
    llflags  as DWORD
end type

' --- shared between threads ---------------------------------------------------
dim shared as HWND hWndMain
dim shared as boolean gEnabled = true
dim shared as long gDoubleTapMs = DELAY_DEFAULT  ' written by main, read by hook
dim shared as long gResetReq = 0           ' main asks hook thread to forget history
' "Where it works" settings - written by main, read by hook
dim shared as boolean gAfterClosers = true   ' also after ) ] } " '
dim shared as boolean gSkipEditors = true
dim shared as boolean gSkipTerminals = true
dim shared as boolean gSkipFullscreen = true
dim shared as boolean gOnlyListed = false    ' false = all apps except list, true = only listed
dim shared as zstring * (APPLIST_MAX + 1) gAppList = "|"   ' "|a.exe|b.exe|"
dim shared as CRITICAL_SECTION gCfgCS      ' guards gAppList
dim shared as long gCfgChanged = 0         ' main asks hook thread to re-check the app
dim shared as CRITICAL_SECTION gCS         ' guards gQ / gQN / gFlushPending
dim shared as QItem gQ(0 to QMAX - 1)
dim shared as long gQN = 0
dim shared as boolean gFlushPending = false
dim shared as HANDLE gCheckReq, gCheckDone
dim shared as long gCheckBusy = 0
dim shared as boolean gCheckResult = false
dim shared as DWORD gOurIL = &hFFFFFFFF    ' our integrity level

' --- hook thread only ---------------------------------------------------------
dim shared as HHOOK gKbHook, gMsHook
dim shared as DWORD gHookTid
dim shared as ubyte gHist(0 to HMAX - 1)
dim shared as long gHistN = 0              ' 0 = we don't know what's before the caret
dim shared as boolean gSpaceDown = false   ' to spot auto-repeat
dim shared as boolean gSpaceValid = false  ' last key was a fresh Space tap
dim shared as DWORD gSpaceTime = 0
dim shared as HWND gLastFg = NULL
dim shared as boolean gFgSkip = true       ' foreground app is excluded/elevated

' --- main thread only ---------------------------------------------------------
dim shared as NOTIFYICONDATA nid
dim shared as UINT gTaskbarCreated
dim shared as zstring * 32 CLASSNAME = "DblSpaceWnd"
dim shared as HICON gIconOn, gIconOff
dim shared as POINT gMenuPt                ' where the tray was clicked
' Settings window
dim shared as zstring * 32 SETCLASS = "DblSpaceSettings"
dim shared as HWND hWndSettings
dim shared as HFONT gSetFont

'==============================================================================
' Typing history (hook thread)
'==============================================================================
sub HistClear()
    gHistN = 0
    gSpaceValid = false
end sub

sub HistPush(byval c as ubyte)
    if gHistN = HMAX then              ' drop the oldest
        memmove(@gHist(0), @gHist(1), HMAX - 1)
        gHistN -= 1
    end if
    gHist(gHistN) = c
    gHistN += 1
end sub

sub HistPop()
    if gHistN > 0 then gHistN -= 1
end sub

function HistAt(byval back as long) as long   ' 0 = last char, 1 = the one before
    if gHistN > back then return gHist(gHistN - 1 - back)
    return 0
end function

'==============================================================================
' Helpers used by the hook thread (fast, never block)
'==============================================================================
function KeyIsDown(byval vk as long) as boolean
    return (GetAsyncKeyState(vk) and &h8000) <> 0
end function

function ChordDown() as boolean      ' Ctrl / Alt / Win held (AltGr doesn't count)
    if KeyIsDown(VK_LWIN) orelse KeyIsDown(VK_RWIN) then return true
    dim as boolean ctrl = KeyIsDown(VK_CONTROL), alt = KeyIsDown(VK_MENU)
    if ctrl andalso alt andalso KeyIsDown(VK_RMENU) then return false   ' AltGr
    return ctrl orelse alt
end function

function IsModifier(byval vk as DWORD) as boolean
    select case vk
    case VK_SHIFT, VK_LSHIFT, VK_RSHIFT, VK_CONTROL, VK_LCONTROL, VK_RCONTROL, _
         VK_MENU, VK_LMENU, VK_RMENU, VK_LWIN, VK_RWIN, VK_CAPITAL, VK_NUMLOCK, VK_SCROLL
        return true
    end select
    return false
end function

' What character does this key type in the foreground app's keyboard layout?
' Returns a C_* class, or 0 if it types nothing (or is a dead key).
function TypedClass(byval vk as DWORD, byval scan as DWORD, byval fg as HWND) as long
    dim as ubyte ks(0 to 255)
    dim as long mods(0 to 8) = {VK_SHIFT, VK_LSHIFT, VK_RSHIFT, VK_CONTROL, VK_LCONTROL, _
                                VK_RCONTROL, VK_MENU, VK_LMENU, VK_RMENU}
    for i as long = 0 to 8
        if KeyIsDown(mods(i)) then ks(mods(i)) = &h80
    next

    dim as WCHAR wb(0 to 7)
    dim as HKL hkl = GetKeyboardLayout(GetWindowThreadProcessId(fg, NULL))
    ' flag 4 = don't disturb the keyboard state (keeps accent/dead keys working)
    dim as long n = ToUnicodeEx(vk, scan, @ks(0), @wb(0), 8, 4, hkl)
    if n <= 0 then return 0

    dim as WCHAR ch = wb(n - 1)
    if IsCharAlphaNumericW(ch) then return C_WORD
    select case ch
    case asc(")"), asc("]"), asc("}"), 34, 39, &h2019, &h201D, &hBB   ' " ' ' " >>
        return C_CLOSER
    end select
    return C_OTHER
end function

function ProcessIL(byval hProc as HANDLE) as DWORD
    dim as DWORD il = &hFFFFFFFF
    dim as HANDLE tok
    if OpenProcessToken(hProc, TOKEN_QUERY, @tok) then
        dim as ULONG_PTR buf(0 to 15)
        dim as DWORD need
        if GetTokenInformation(tok, TokenIntegrityLevel, @buf(0), sizeof(buf), @need) then
            dim as TOKEN_MANDATORY_LABEL ptr tml = cast(any ptr, @buf(0))
            dim as PSID sid = tml->Label.Sid
            il = *GetSidSubAuthority(sid, *GetSidSubAuthorityCount(sid) - 1)
        end if
        CloseHandle(tok)
    end if
    return il
end function

function InList(byval list as const zstring ptr, byval item as const zstring ptr) as boolean
    dim as zstring * 300 key
    if lstrlenA(item) > 280 then return false
    lstrcpyA(@key, "|")
    lstrcatA(@key, item)
    lstrcatA(@key, "|")
    CharLowerA(@key)
    return strstr(list, @key) <> NULL
end function

function InAppList(byval exeName as const zstring ptr) as boolean
    EnterCriticalSection(@gCfgCS)
    dim as boolean r = InList(@gAppList, exeName)
    LeaveCriticalSection(@gCfgCS)
    return r
end function

' Should this foreground window be left alone? (checked once per window
' switch, and again when Settings change)
function ComputeSkip(byval fg as HWND) as boolean
    if fg = NULL then return true

    dim as zstring * 260 wcls, path
    GetClassNameA(fg, @wcls, 256)

    dim as DWORD pid
    GetWindowThreadProcessId(fg, @pid)
    dim as HANDLE hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)
    if hp = NULL then return true

    dim as zstring ptr exeName = @path
    dim as DWORD sz = 260
    if QueryFullProcessImageNameA(hp, 0, @path, @sz) then
        exeName = strrchr(@path, asc("\"))
        if exeName then exeName += 1 else exeName = @path
    end if

    dim as boolean skip
    if gOnlyListed then
        skip = not InAppList(exeName)       ' only the apps in the list
    else
        skip = InAppList(exeName)           ' every app except the list...
        if gSkipTerminals andalso (InList(TERMINAL_CLASSES, @wcls) orelse InList(TERMINAL_EXES, exeName)) then skip = true
        if gSkipEditors andalso InList(EDITOR_EXES, exeName) then skip = true
    end if

    ' Windows blocks typing into apps running with more rights than us
    if not skip andalso gOurIL <> &hFFFFFFFF then
        dim as DWORD il = ProcessIL(hp)
        if il = &hFFFFFFFF orelse il > gOurIL then skip = true
    end if

    CloseHandle(hp)
    return skip
end function

function IsFullscreen(byval fg as HWND) as boolean    ' games, videos, F11
    if IsZoomed(fg) then return false
    dim as RECT r
    if GetWindowRect(fg, @r) = 0 then return false
    dim as MONITORINFO mi
    mi.cbSize = sizeof(mi)
    if GetMonitorInfo(MonitorFromWindow(fg, MONITOR_DEFAULTTONEAREST), @mi) = 0 then return false
    return r.left <= mi.rcMonitor.left andalso r.top <= mi.rcMonitor.top andalso _
           r.right >= mi.rcMonitor.right andalso r.bottom >= mi.rcMonitor.bottom
end function

' Update the history for a real key press. Returns true if this press is the
' 2nd Space of a double tap that should become ". ".
function OnKeyDown(byval kb as KbHookData ptr, byval fg as HWND) as boolean
    dim as DWORD vk = kb->vkCode
    if IsModifier(vk) then return false

    if vk = VK_SPACE then
        if gSpaceDown then                     ' held down: auto-repeat
            HistPush(C_SPACE)
            gSpaceValid = false
            return false
        end if
        gSpaceDown = true
        if ChordDown() then HistClear() : return false

        dim as boolean afterWord = cbool(HistAt(1) = C_WORD) orelse (gAfterClosers andalso cbool(HistAt(1) = C_CLOSER))
        dim as boolean quick = cbool(cast(DWORD, kb->tstamp - gSpaceTime) <= cast(DWORD, gDoubleTapMs))
        if gSpaceValid andalso cbool(HistAt(0) = C_SPACE) andalso afterWord andalso quick _
           andalso not gFgSkip andalso not (gSkipFullscreen andalso IsFullscreen(fg)) then
            HistPop()                           ' "word " -> "word. "
            HistPush(C_OTHER)
            HistPush(C_SPACE)
            gSpaceValid = false
            return true
        end if

        HistPush(C_SPACE)
        gSpaceValid = true
        gSpaceTime = kb->tstamp
        return false
    end if

    gSpaceValid = false
    if ChordDown() then HistClear() : return false      ' Ctrl+V, Ctrl+Z, ...

    select case vk
    case VK_BACK
        HistPop()
    case VK_DELETE
        ' deletes after the caret; what's before it is unchanged
    case VK_TAB, VK_ESCAPE, VK_LEFT, VK_RIGHT, VK_UP, VK_DOWN, VK_HOME, VK_END, _
         VK_PRIOR, VK_NEXT, VK_INSERT, VK_APPS, VK_F1 to VK_F24
        HistClear()                             ' caret may have moved
    case else
        dim as long c = TypedClass(vk, kb->scanCode, fg)
        if c then HistPush(c)
    end select
    return false
end function

'==============================================================================
' Hooks (hook thread)
'==============================================================================
function KbProc stdcall (byval nCode as long, byval wParam as WPARAM, byval lParam as LPARAM) as LRESULT
    if nCode <> HC_ACTION then return CallNextHookEx(NULL, nCode, wParam, lParam)
    dim as KbHookData ptr kb = cast(KbHookData ptr, lParam)

    ' Ignore keystrokes we (or other tools) injected
    if kb->flags and LLKHF_INJECTED then return CallNextHookEx(NULL, nCode, wParam, lParam)

    dim as boolean isDown = (wParam = WM_KEYDOWN) orelse (wParam = WM_SYSKEYDOWN)
    if kb->vkCode = VK_SPACE andalso not isDown then gSpaceDown = false

    dim as boolean makePeriod = false
    if gEnabled then
        if gResetReq then gResetReq = 0 : HistClear()
        dim as HWND fg = GetForegroundWindow()
        if fg <> gLastFg orelse gCfgChanged then    ' switched apps / new settings
            gCfgChanged = 0
            gLastFg = fg
            gFgSkip = ComputeSkip(fg)
            HistClear()
        end if
        if isDown then makePeriod = OnKeyDown(kb, fg)
    end if

    ' While a period is pending, hold back every key so order is kept
    EnterCriticalSection(@gCS)
    if (makePeriod orelse gFlushPending) andalso gQN < QMAX then
        with gQ(gQN)
            .isPeriod = makePeriod
            .isUp = not isDown
            .vk = kb->vkCode
            .scan = kb->scanCode
            .llflags = kb->flags
        end with
        gQN += 1
        if not gFlushPending then
            gFlushPending = true
            PostMessage(hWndMain, WM_FLUSH, 0, 0)
        end if
        LeaveCriticalSection(@gCS)
        return 1                                ' swallowed; replayed by DoFlush
    end if
    LeaveCriticalSection(@gCS)

    return CallNextHookEx(NULL, nCode, wParam, lParam)
end function

function MsProc stdcall (byval nCode as long, byval wParam as WPARAM, byval lParam as LPARAM) as LRESULT
    if nCode = HC_ACTION then
        select case wParam
        case WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN
            HistClear()                         ' a click may move the caret
        end select
    end if
    return CallNextHookEx(NULL, nCode, wParam, lParam)
end function

function HookThread stdcall (byval ready as any ptr) as DWORD
    dim as MSG m
    PeekMessage(@m, NULL, 0, 0, PM_NOREMOVE)    ' create the message queue
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST)

    dim as HINSTANCE hInst = GetModuleHandle(NULL)
    gKbHook = SetWindowsHookEx(WH_KEYBOARD_LL, cast(HOOKPROC, @KbProc), hInst, 0)
    gMsHook = SetWindowsHookEx(WH_MOUSE_LL, cast(HOOKPROC, @MsProc), hInst, 0)
    SetEvent(cast(HANDLE, ready))
    if gKbHook = NULL then return 1

    while GetMessage(@m, NULL, 0, 0) > 0
        DispatchMessage(@m)
    wend
    UnhookWindowsHookEx(gKbHook)
    if gMsHook then UnhookWindowsHookEx(gMsHook)
    return 0
end function

'==============================================================================
' Password / IME check (checker thread - may be slow, so it has a timeout)
'==============================================================================
function AccStateProtected(byval acc as IAccessible ptr, byval child as VARIANT) as boolean
    dim as VARIANT st
    VariantInit(@st)
    dim as boolean r = false
    if acc->lpVtbl->get_accState(acc, child, @st) = S_OK then
        if st.vt = VT_I4 then r = (st.lVal and STATE_SYSTEM_PROTECTED) <> 0
    end if
    VariantClear(@st)
    return r
end function

' Is the focused element a password box? Works for browsers and most apps.
function AccFocusIsProtected(byval hwnd as HWND) as boolean
    dim as IAccessible ptr acc = NULL
    if AccessibleObjectFromWindow(hwnd, OBJID_CLIENT, @IID_IAccessible, cast(any ptr ptr, @acc)) <> S_OK _
       orelse acc = NULL then return false

    dim as boolean result = false, done = false
    for depth as long = 1 to 8                  ' walk down to the focused element
        dim as VARIANT f
        VariantInit(@f)
        if acc->lpVtbl->get_accFocus(acc, @f) <> S_OK then exit for
        if f.vt = VT_DISPATCH andalso f.pdispVal <> NULL then
            dim as IAccessible ptr nxt = NULL
            dim as HRESULT hr = f.pdispVal->lpVtbl->QueryInterface(f.pdispVal, @IID_IAccessible, cast(any ptr ptr, @nxt))
            VariantClear(@f)
            if hr <> S_OK orelse nxt = NULL then exit for
            acc->lpVtbl->Release(acc)
            acc = nxt
        elseif f.vt = VT_I4 andalso f.lVal <> CHILDID_SELF then
            result = AccStateProtected(acc, f)
            done = true
            exit for
        else
            VariantClear(@f)
            exit for
        end if
    next

    if not done then
        dim as VARIANT self
        VariantInit(@self)
        self.vt = VT_I4
        self.lVal = CHILDID_SELF
        result = AccStateProtected(acc, self)
    end if
    acc->lpVtbl->Release(acc)
    return result
end function

' Chinese/Japanese/Korean IME switched on and in native mode -> Space belongs to it
function ImeComposing(byval hf as HWND, byval tid as DWORD) as boolean
    dim as UINT_PTR lang = cast(UINT_PTR, GetKeyboardLayout(tid)) and &h3FF
    if lang <> &h04 andalso lang <> &h11 andalso lang <> &h12 then return false
    dim as HWND hime = ImmGetDefaultIMEWnd(hf)
    if hime = NULL then return false
    dim as DWORD_PTR r = 0
    if SendMessageTimeoutA(hime, WM_IME_CONTROL, IMC_GETOPENSTATUS, 0, SMTO_ABORTIFHUNG, 60, @r) = 0 then return true
    if r = 0 then return false
    r = 0
    if SendMessageTimeoutA(hime, WM_IME_CONTROL, IMC_GETCONVERSIONMODE, 0, SMTO_ABORTIFHUNG, 60, @r) = 0 then return true
    return (r and IME_CMODE_NATIVE) <> 0
end function

function FocusBlocksPeriod() as boolean
    dim as HWND fg = GetForegroundWindow()
    if fg = NULL then return true
    if IsHungAppWindow(fg) then return true
    dim as DWORD tid = GetWindowThreadProcessId(fg, NULL)

    dim as HWND hf = fg
    dim as GUITHREADINFO gti
    gti.cbSize = sizeof(gti)
    if GetGUIThreadInfo(tid, @gti) andalso gti.hwndFocus <> NULL then hf = gti.hwndFocus

    dim as zstring * 64 wcls
    GetClassNameA(hf, @wcls, 64)
    if lstrcmpiA(@wcls, "Edit") = 0 andalso (GetWindowLongPtr(hf, GWL_STYLE) and ES_PASSWORD) then return true

    if ImeComposing(hf, tid) then return true
    return AccFocusIsProtected(hf)
end function

function CheckerThread stdcall (byval p as any ptr) as DWORD
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED)
    do
        WaitForSingleObject(gCheckReq, INFINITE)
        gCheckResult = FocusBlocksPeriod()
        SetEvent(gCheckDone)
        gCheckBusy = 0                          ' after SetEvent, see PeriodAllowedNow
    loop
    return 0
end function

' Main thread: ask the checker, but never wait long. Unsure -> plain space.
function PeriodAllowedNow() as boolean
    if gCheckBusy then return false             ' still stuck on an earlier check
    gCheckBusy = 1
    ResetEvent(gCheckDone)
    SetEvent(gCheckReq)
    if WaitForSingleObject(gCheckDone, CHECK_TIMEOUT_MS) <> WAIT_OBJECT_0 then return false
    return not gCheckResult
end function

'==============================================================================
' Typing the period + replaying held-back keys (main thread)
'==============================================================================
sub AddKey(ins() as KbInput, byref k as long, byval vk as WORD, byval scan as WORD, byval flags as DWORD)
    clear ins(k), 0, sizeof(KbInput)
    ins(k).itype = INPUT_KEYBOARD
    ins(k).wVk = vk
    ins(k).wScan = scan
    ins(k).dwFlags = flags
    k += 1
end sub

sub DoFlush()
    static as QItem items(0 to QMAX - 1)
    static as KbInput ins(0 to QMAX * 6 - 1)
    dim as boolean decided = false, usePeriod = false

    do
        EnterCriticalSection(@gCS)
        dim as long n = gQN
        for i as long = 0 to n - 1
            items(i) = gQ(i)
        next
        gQN = 0
        LeaveCriticalSection(@gCS)

        dim as long k = 0
        for i as long = 0 to n - 1
            if items(i).isPeriod then
                if not decided then
                    usePeriod = gEnabled andalso PeriodAllowedNow()
                    decided = true
                end if
                if usePeriod then
                    ' Backspace (removes the 1st space), then ". " as Unicode
                    ' so it works with any keyboard layout
                    AddKey(ins(), k, VK_BACK, 0, 0)
                    AddKey(ins(), k, VK_BACK, 0, KEYEVENTF_KEYUP)
                    AddKey(ins(), k, 0, &h2E, KEYEVENTF_UNICODE)
                    AddKey(ins(), k, 0, &h2E, KEYEVENTF_UNICODE or KEYEVENTF_KEYUP)
                    AddKey(ins(), k, 0, &h20, KEYEVENTF_UNICODE)
                    AddKey(ins(), k, 0, &h20, KEYEVENTF_UNICODE or KEYEVENTF_KEYUP)
                else
                    AddKey(ins(), k, VK_SPACE, &h39, 0)     ' give the Space back
                end if
            else
                dim as DWORD fl = 0
                if items(i).isUp then fl or= KEYEVENTF_KEYUP
                if items(i).llflags and LLKHF_EXTENDED then fl or= KEYEVENTF_EXTENDEDKEY
                AddKey(ins(), k, items(i).vk, items(i).scan, fl)
            end if
        next
        if k then SendInput(k, cast(any ptr, @ins(0)), sizeof(KbInput))

        ' More keys may have arrived while we were sending
        EnterCriticalSection(@gCS)
        if gQN = 0 then
            gFlushPending = false
            LeaveCriticalSection(@gCS)
            exit do
        end if
        LeaveCriticalSection(@gCS)
    loop
end sub

'==============================================================================
' Start with Windows
'==============================================================================
function AutoStartOn() as boolean
    dim as HKEY hk
    if RegOpenKeyExA(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_QUERY_VALUE, @hk) <> ERROR_SUCCESS then return false
    dim as long r = RegQueryValueExA(hk, RUN_VALUE, NULL, NULL, NULL, NULL)
    RegCloseKey(hk)
    return r = ERROR_SUCCESS
end function

sub SetAutoStart(byval enable as boolean)
    dim as HKEY hk
    if RegOpenKeyExA(HKEY_CURRENT_USER, RUN_KEY, 0, KEY_SET_VALUE, @hk) <> ERROR_SUCCESS then exit sub
    if enable then
        dim as zstring * (MAX_PATH + 1) exe
        dim as zstring * (MAX_PATH + 3) cmd
        GetModuleFileNameA(NULL, @exe, MAX_PATH)
        cmd = chr(34) & exe & chr(34)
        RegSetValueExA(hk, RUN_VALUE, 0, REG_SZ, cast(BYTE ptr, @cmd), len(cmd) + 1)
    else
        RegDeleteValueA(hk, RUN_VALUE)
    end if
    RegCloseKey(hk)
end sub

'==============================================================================
' Tray icon + window (main thread)
'==============================================================================
' Load the ON/OFF icons at the current tray size (16px at 100%, 20px at 125%,
' 24px at 150%...). Called again when Explorer restarts, which also happens
' when the display scaling changes.
sub LoadTrayIcons()
    if gIconOn then DestroyIcon(gIconOn)
    if gIconOff then DestroyIcon(gIconOff)
    dim as HINSTANCE hInst = GetModuleHandle(NULL)
    dim as long cx = GetSystemMetrics(SM_CXSMICON), cy = GetSystemMetrics(SM_CYSMICON)
    gIconOn  = LoadImage(hInst, MAKEINTRESOURCE(IDI_ON),  IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR)
    gIconOff = LoadImage(hInst, MAKEINTRESOURCE(IDI_OFF), IMAGE_ICON, cx, cy, LR_DEFAULTCOLOR)
    ' Built without dblspace.rc? Fall back to the generic icon.
    if gIconOn = NULL then gIconOn = CopyIcon(LoadIcon(NULL, IDI_APPLICATION))
    if gIconOff = NULL then gIconOff = CopyIcon(gIconOn)
end sub

sub TraySetState()                     ' icon + tooltip for the current ON/OFF state
    if gEnabled then
        nid.hIcon = gIconOn
        nid.szTip = "Double-space period: ON"
    else
        nid.hIcon = gIconOff
        nid.szTip = "Double-space period: OFF"
    end if
end sub

' Returns false if the taskbar isn't ready yet (e.g. right after logon).
function TrayAdd() as boolean
    LoadTrayIcons()
    nid.cbSize = sizeof(NOTIFYICONDATA)
    nid.hWnd = hWndMain
    nid.uID = 1
    nid.uFlags = NIF_ICON or NIF_MESSAGE or NIF_TIP
    nid.uCallbackMessage = WM_TRAY
    TraySetState()
    Shell_NotifyIcon(NIM_DELETE, @nid)  ' in case it's still there
    return Shell_NotifyIcon(NIM_ADD, @nid) <> 0
end function

sub TrayAddOrRetry()
    if TrayAdd() then
        KillTimer(hWndMain, IDT_TRAYRETRY)
    else
        SetTimer(hWndMain, IDT_TRAYRETRY, 2000, NULL)
    end if
end sub

sub TrayUpdate()
    nid.uFlags = NIF_ICON or NIF_TIP
    TraySetState()
    Shell_NotifyIcon(NIM_MODIFY, @nid)
end sub


'==============================================================================
' Settings (registry: HKCU\Software\DblSpace)
'==============================================================================
function ClampDelay(byval ms as long) as long
    ms = ((ms + DELAY_STEP \ 2) \ DELAY_STEP) * DELAY_STEP
    if ms < DELAY_MIN then ms = DELAY_MIN
    if ms > DELAY_MAX then ms = DELAY_MAX
    return ms
end function

function RegGetDword(byval hk as HKEY, byval name_ as const zstring ptr, byval def as long) as long
    dim as DWORD v, sz = sizeof(DWORD), typ
    if RegQueryValueExA(hk, name_, NULL, @typ, cast(BYTE ptr, @v), @sz) = ERROR_SUCCESS _
       andalso typ = REG_DWORD then return v
    return def
end function

sub RegSetDword(byval hk as HKEY, byval name_ as const zstring ptr, byval v as DWORD)
    RegSetValueExA(hk, name_, 0, REG_DWORD, cast(BYTE ptr, @v), sizeof(DWORD))
end sub

' Called once at startup, before the hook thread exists
sub LoadSettings()
    dim as HKEY hk
    if RegOpenKeyExA(HKEY_CURRENT_USER, CFG_KEY, 0, KEY_QUERY_VALUE, @hk) <> ERROR_SUCCESS then exit sub
    gDoubleTapMs    = ClampDelay(RegGetDword(hk, "DoubleTapMs", DELAY_DEFAULT))
    gEnabled        = RegGetDword(hk, "Enabled", 1) <> 0
    gAfterClosers   = RegGetDword(hk, "AfterClosers", 1) <> 0
    gSkipEditors    = RegGetDword(hk, "SkipEditors", 1) <> 0
    gSkipTerminals  = RegGetDword(hk, "SkipTerminals", 1) <> 0
    gSkipFullscreen = RegGetDword(hk, "SkipFullscreen", 1) <> 0
    gOnlyListed     = RegGetDword(hk, "OnlyListed", 0) <> 0

    dim as zstring * (APPLIST_MAX + 1) buf
    dim as DWORD sz = APPLIST_MAX, typ
    if RegQueryValueExA(hk, "Apps", NULL, @typ, cast(BYTE ptr, @buf), @sz) = ERROR_SUCCESS _
       andalso typ = REG_SZ andalso left(buf, 1) = "|" andalso right(buf, 1) = "|" then
        gAppList = buf
    end if
    RegCloseKey(hk)
end sub

sub SaveSettings()
    dim as HKEY hk
    if RegCreateKeyExA(HKEY_CURRENT_USER, CFG_KEY, 0, NULL, 0, KEY_SET_VALUE, NULL, @hk, NULL) <> ERROR_SUCCESS then exit sub
    RegSetDword(hk, "DoubleTapMs", gDoubleTapMs)
    RegSetDword(hk, "Enabled", iif(gEnabled, 1, 0))
    RegSetDword(hk, "AfterClosers", iif(gAfterClosers, 1, 0))
    RegSetDword(hk, "SkipEditors", iif(gSkipEditors, 1, 0))
    RegSetDword(hk, "SkipTerminals", iif(gSkipTerminals, 1, 0))
    RegSetDword(hk, "SkipFullscreen", iif(gSkipFullscreen, 1, 0))
    RegSetDword(hk, "OnlyListed", iif(gOnlyListed, 1, 0))
    RegSetValueExA(hk, "Apps", 0, REG_SZ, cast(BYTE ptr, @gAppList), len(gAppList) + 1)
    RegCloseKey(hk)
end sub

'==============================================================================
' Settings window (main thread). Every change applies and saves immediately;
' "Close" (or Esc) just closes it.
'==============================================================================
type PFN_GetDpiForWindow as function stdcall (byval as HWND) as UINT
type PFN_AdjustWindowRectExForDpi as function stdcall (byval as RECT ptr, byval as DWORD, byval as WINBOOL, byval as DWORD, byval as UINT) as WINBOOL

function WindowDpi(byval hWnd as HWND) as long
    ' GetDpiForWindow needs Windows 10 1607+, so look it up at runtime
    static as PFN_GetDpiForWindow pfn = NULL
    static as boolean tried = false
    if not tried then
        tried = true
        pfn = cast(PFN_GetDpiForWindow, GetProcAddress(GetModuleHandle("user32.dll"), "GetDpiForWindow"))
    end if
    if pfn then
        dim as long d = pfn(hWnd)
        if d > 0 then return d
    end if
    dim as HDC hdc = GetDC(NULL)
    dim as long d = GetDeviceCaps(hdc, LOGPIXELSY)
    ReleaseDC(NULL, hdc)
    return d
end function

' Window size for a given client size, with the title bar sized for this DPI
sub ClientToWindowSize(byval st as DWORD, byval dpi as long, byref w as long, byref h as long)
    static as PFN_AdjustWindowRectExForDpi pfn = NULL
    static as boolean tried = false
    if not tried then
        tried = true
        pfn = cast(PFN_AdjustWindowRectExForDpi, GetProcAddress(GetModuleHandle("user32.dll"), "AdjustWindowRectExForDpi"))
    end if
    dim as RECT r = (0, 0, w, h)
    if pfn then pfn(@r, st, FALSE, 0, dpi) else AdjustWindowRectEx(@r, st, FALSE, 0)
    w = r.right - r.left
    h = r.bottom - r.top
end sub

' Each control's position in DIPs (96 dpi units), scaled on layout
type CtlPos
    id as long
    x as long
    y as long
    w as long
    h as long
end type
dim shared as CtlPos gCtl(0 to 31)
dim shared as long gCtlN = 0

const SET_W = 440                       ' client size in DIPs
const SET_H = 534
const SET_STYLE = WS_CAPTION or WS_SYSMENU or WS_MINIMIZEBOX

sub AddCtl(byval hWnd as HWND, byval wcls as const zstring ptr, byval text as string, byval style as DWORD, _
           byval id as long, byval x as long, byval y as long, byval w as long, byval h as long, byval exStyle as DWORD = 0)
    CreateWindowEx(exStyle, wcls, strptr(text), WS_CHILD or WS_VISIBLE or style, 0, 0, 0, 0, _
                   hWnd, cast(HMENU, cast(INT_PTR, id)), GetModuleHandle(NULL), NULL)
    gCtl(gCtlN).id = id : gCtl(gCtlN).x = x : gCtl(gCtlN).y = y : gCtl(gCtlN).w = w : gCtl(gCtlN).h = h
    gCtlN += 1
end sub

sub SetCheck(byval hWnd as HWND, byval id as long, byval b as boolean)
    CheckDlgButton(hWnd, id, iif(b, BST_CHECKED, BST_UNCHECKED))
end sub

function GetCheck(byval hWnd as HWND, byval id as long) as boolean
    return IsDlgButtonChecked(hWnd, id) = BST_CHECKED
end function

sub SettingsUpdateSpeedLabel(byval hWnd as HWND)
    SetDlgItemText(hWnd, IDC_SPEEDLBL, "Double-tap speed:  " & gDoubleTapMs & " ms  (max time between the two Space taps)")
end sub

' Grey out what doesn't apply right now
sub SettingsUpdateEnables(byval hWnd as HWND)
    dim as WINBOOL allMode = iif(gOnlyListed, FALSE, TRUE)
    EnableWindow(GetDlgItem(hWnd, IDC_SKIPEDIT), allMode)   ' categories only matter in
    EnableWindow(GetDlgItem(hWnd, IDC_SKIPTERM), allMode)   ' "all apps except..." mode
    EnableWindow(GetDlgItem(hWnd, IDC_SKIPFULL), allMode)
    dim as boolean hasSel = SendDlgItemMessage(hWnd, IDC_LIST, LB_GETCURSEL, 0, 0) >= 0
    EnableWindow(GetDlgItem(hWnd, IDC_REMOVE), iif(hasSel, TRUE, FALSE))
end sub

' Copy all settings into the controls
sub SettingsSync(byval hWnd as HWND)
    SetCheck(hWnd, IDC_ENABLED, gEnabled)
    SetCheck(hWnd, IDC_AUTOSTART, AutoStartOn())
    SetCheck(hWnd, IDC_CLOSERS, gAfterClosers)
    SetCheck(hWnd, IDC_SKIPEDIT, gSkipEditors)
    SetCheck(hWnd, IDC_SKIPTERM, gSkipTerminals)
    SetCheck(hWnd, IDC_SKIPFULL, gSkipFullscreen)
    CheckRadioButton(hWnd, IDC_MODE_ALL, IDC_MODE_ONLY, iif(gOnlyListed, IDC_MODE_ONLY, IDC_MODE_ALL))
    SendDlgItemMessage(hWnd, IDC_SLIDER, TBM_SETPOS, TRUE, gDoubleTapMs \ DELAY_STEP)
    SettingsUpdateSpeedLabel(hWnd)

    ' "|a.exe|b.exe|" -> list box
    SendDlgItemMessage(hWnd, IDC_LIST, LB_RESETCONTENT, 0, 0)
    dim as string s = gAppList
    dim as long p = 2
    do
        dim as long q = instr(p, s, "|")
        if q = 0 then exit do
        if q > p then
            dim as string item = mid(s, p, q - p)
            SendDlgItemMessage(hWnd, IDC_LIST, LB_ADDSTRING, 0, cast(LPARAM, strptr(item)))
        end if
        p = q + 1
    loop
    SettingsUpdateEnables(hWnd)
end sub

' List box -> gAppList (shared with the hook thread). False if it's too long.
function SettingsStoreList(byval hWnd as HWND) as boolean
    dim as string s = "|"
    dim as long n = SendDlgItemMessage(hWnd, IDC_LIST, LB_GETCOUNT, 0, 0)
    for i as long = 0 to n - 1
        dim as zstring * 300 item
        if SendDlgItemMessage(hWnd, IDC_LIST, LB_GETTEXTLEN, i, 0) < 280 then
            SendDlgItemMessage(hWnd, IDC_LIST, LB_GETTEXT, i, cast(LPARAM, @item))
            s &= item & "|"
        end if
    next
    if len(s) > APPLIST_MAX then return false
    EnterCriticalSection(@gCfgCS)
    gAppList = s
    LeaveCriticalSection(@gCfgCS)
    gCfgChanged = 1
    SaveSettings()
    return true
end function

sub SettingsAddApp(byval hWnd as HWND, byval exeName as string)
    exeName = lcase(trim(exeName))
    if len(exeName) = 0 orelse len(exeName) >= 280 orelse instr(exeName, "|") then exit sub
    dim as long idx = SendDlgItemMessage(hWnd, IDC_LIST, LB_FINDSTRINGEXACT, -1, cast(LPARAM, strptr(exeName)))
    if idx < 0 then
        idx = SendDlgItemMessage(hWnd, IDC_LIST, LB_ADDSTRING, 0, cast(LPARAM, strptr(exeName)))
        if not SettingsStoreList(hWnd) then
            SendDlgItemMessage(hWnd, IDC_LIST, LB_DELETESTRING, idx, 0)
            MessageBox(hWnd, "The app list is full. Remove some apps first.", "DblSpace", MB_ICONWARNING)
            exit sub
        end if
    end if
    SendDlgItemMessage(hWnd, IDC_LIST, LB_SETCURSEL, idx, 0)
    SettingsUpdateEnables(hWnd)
end sub

' --- "Add app..." menu: the apps that have a window open right now ---------
dim shared as string gRunApps(0 to 39)
dim shared as long gRunN

function EnumAppsProc stdcall (byval h as HWND, byval l as LPARAM) as WINBOOL
    if IsWindowVisible(h) = 0 orelse GetWindow(h, GW_OWNER) <> NULL then return TRUE
    if GetWindowLong(h, GWL_EXSTYLE) and WS_EX_TOOLWINDOW then return TRUE
    if GetWindowTextLength(h) = 0 then return TRUE
    dim as DWORD pid
    GetWindowThreadProcessId(h, @pid)
    if pid = GetCurrentProcessId() then return TRUE

    dim as HANDLE hp = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)
    if hp = NULL then return TRUE
    dim as zstring * 260 path
    dim as DWORD sz = 260
    dim as boolean ok = QueryFullProcessImageNameA(hp, 0, @path, @sz) <> 0
    CloseHandle(hp)
    if not ok then return TRUE

    dim as string nm = path
    nm = lcase(mid(nm, instrrev(nm, "\") + 1))
    if nm = "applicationframehost.exe" orelse nm = "textinputhost.exe" then return TRUE

    ' insert sorted, no duplicates
    dim as long i = 0
    while i < gRunN andalso gRunApps(i) < nm
        i += 1
    wend
    if i < gRunN andalso gRunApps(i) = nm then return TRUE
    if gRunN > ubound(gRunApps) then return FALSE
    for j as long = gRunN to i + 1 step -1
        gRunApps(j) = gRunApps(j - 1)
    next
    gRunApps(i) = nm
    gRunN += 1
    return TRUE
end function

sub SettingsBrowseApp(byval hWnd as HWND)
    dim as zstring * 520 file
    dim as string filter = "Programs (*.exe)" & chr(0) & "*.exe" & chr(0) & chr(0)
    dim as OPENFILENAME ofn
    ofn.lStructSize = sizeof(ofn)
    ofn.hwndOwner = hWnd
    ofn.lpstrFilter = strptr(filter)
    ofn.lpstrFile = @file
    ofn.nMaxFile = 520
    ofn.lpstrTitle = @"Choose a program"
    ofn.Flags = OFN_FILEMUSTEXIST or OFN_HIDEREADONLY or OFN_NOCHANGEDIR
    if GetOpenFileName(@ofn) then
        dim as string p = file
        SettingsAddApp(hWnd, mid(p, instrrev(p, "\") + 1))
    end if
end sub

sub SettingsShowAddMenu(byval hWnd as HWND)
    gRunN = 0
    EnumWindows(cast(WNDENUMPROC, @EnumAppsProc), 0)

    dim as HMENU m = CreatePopupMenu()
    for i as long = 0 to gRunN - 1
        dim as boolean listed = SendDlgItemMessage(hWnd, IDC_LIST, LB_FINDSTRINGEXACT, -1, cast(LPARAM, strptr(gRunApps(i)))) >= 0
        AppendMenu(m, MF_STRING or iif(listed, MF_GRAYED or MF_CHECKED, 0), IDM_ADD_FIRST + i, gRunApps(i))
    next
    if gRunN then AppendMenu(m, MF_SEPARATOR, 0, NULL)
    AppendMenu(m, MF_STRING, IDM_ADD_BROWSE, "Browse for a program...")

    dim as RECT r
    GetWindowRect(GetDlgItem(hWnd, IDC_ADD), @r)
    dim as long cmd = TrackPopupMenu(m, TPM_RETURNCMD or TPM_NONOTIFY or TPM_LEFTALIGN or TPM_TOPALIGN, _
                                     r.left, r.bottom, 0, hWnd, NULL)
    DestroyMenu(m)

    if cmd = IDM_ADD_BROWSE then
        SettingsBrowseApp(hWnd)
    elseif cmd >= IDM_ADD_FIRST andalso cmd < IDM_ADD_FIRST + gRunN then
        SettingsAddApp(hWnd, gRunApps(cmd - IDM_ADD_FIRST))
    end if
end sub

' Size and place everything for this DPI. center = true: centre on the
' monitor's work area; otherwise put the window at (x, y).
sub SettingsLayout(byval hWnd as HWND, byval dpi as long, byval center as boolean, byval x as long, byval y as long)
    #define S(v) MulDiv(v, dpi, 96)

    ' Windows' message font, scaled to this monitor
    dim as NONCLIENTMETRICS ncm
    ncm.cbSize = sizeof(ncm)
    SystemParametersInfo(SPI_GETNONCLIENTMETRICS, sizeof(ncm), @ncm, 0)
    dim as HDC hdc = GetDC(NULL)
    dim as long sysDpi = GetDeviceCaps(hdc, LOGPIXELSY)
    ReleaseDC(NULL, hdc)
    ncm.lfMessageFont.lfHeight = MulDiv(ncm.lfMessageFont.lfHeight, dpi, sysDpi)
    dim as HFONT oldFont = gSetFont
    gSetFont = CreateFontIndirect(@ncm.lfMessageFont)

    for i as long = 0 to gCtlN - 1
        dim as HWND c = GetDlgItem(hWnd, gCtl(i).id)
        MoveWindow(c, S(gCtl(i).x), S(gCtl(i).y), S(gCtl(i).w), S(gCtl(i).h), FALSE)
        SendMessage(c, WM_SETFONT, cast(WPARAM, gSetFont), FALSE)
    next
    if oldFont then DeleteObject(oldFont)

    dim as long w = S(SET_W), h = S(SET_H)
    ClientToWindowSize(SET_STYLE, dpi, w, h)
    if center then
        dim as MONITORINFO mi
        mi.cbSize = sizeof(mi)
        GetMonitorInfo(MonitorFromWindow(hWnd, MONITOR_DEFAULTTONEAREST), @mi)
        x = mi.rcWork.left + (mi.rcWork.right - mi.rcWork.left - w) \ 2
        y = mi.rcWork.top + (mi.rcWork.bottom - mi.rcWork.top - h) \ 2
    end if
    SetWindowPos(hWnd, NULL, x, y, w, h, SWP_NOZORDER or SWP_NOACTIVATE)
    InvalidateRect(hWnd, NULL, TRUE)
    #undef S
end sub

function SettingsProc stdcall (byval hWnd as HWND, byval uMsg as UINT, byval wParam as WPARAM, byval lParam as LPARAM) as LRESULT
    select case uMsg
    case WM_CREATE
        const CB = BS_AUTOCHECKBOX or WS_TABSTOP
        gCtlN = 0
        ' --- Typing ---
        AddCtl(hWnd, "BUTTON", "Typing", BS_GROUPBOX, IDC_GRP_TYPING, 12, 8, 416, 158)
        AddCtl(hWnd, "BUTTON", "Enabled", CB or WS_GROUP, IDC_ENABLED, 26, 30, 180, 22)
        AddCtl(hWnd, "BUTTON", "Start with Windows", CB, IDC_AUTOSTART, 220, 30, 196, 22)
        AddCtl(hWnd, "STATIC", "", SS_NOPREFIX, IDC_SPEEDLBL, 26, 60, 390, 20)
        AddCtl(hWnd, TRACKBAR_CLASS, "", WS_TABSTOP or TBS_HORZ or TBS_AUTOTICKS, IDC_SLIDER, 20, 80, 402, 30)
        AddCtl(hWnd, "STATIC", "Quick (" & DELAY_MIN & " ms)", SS_NOPREFIX, IDC_MINLBL, 26, 110, 150, 18)
        AddCtl(hWnd, "STATIC", "Relaxed (1 s)", SS_NOPREFIX or SS_RIGHT, IDC_MAXLBL, 266, 110, 150, 18)
        AddCtl(hWnd, "BUTTON", "Also after closing quotes and brackets   ) ] } "" '", CB, IDC_CLOSERS, 26, 134, 390, 22)
        ' --- Where it works ---
        AddCtl(hWnd, "BUTTON", "Where it works", BS_GROUPBOX, IDC_GRP_WHERE, 12, 176, 416, 306)
        AddCtl(hWnd, "BUTTON", "In all apps, except the ones listed below", BS_AUTORADIOBUTTON or WS_TABSTOP or WS_GROUP, IDC_MODE_ALL, 26, 198, 390, 22)
        AddCtl(hWnd, "BUTTON", "Only in the apps listed below", BS_AUTORADIOBUTTON, IDC_MODE_ONLY, 26, 220, 390, 22)
        AddCtl(hWnd, "LISTBOX", "", LBS_SORT or LBS_NOTIFY or LBS_NOINTEGRALHEIGHT or WS_VSCROLL or WS_TABSTOP or WS_GROUP, _
               IDC_LIST, 26, 248, 280, 104, WS_EX_CLIENTEDGE)
        AddCtl(hWnd, "BUTTON", "Add app...", WS_TABSTOP, IDC_ADD, 316, 248, 100, 28)
        AddCtl(hWnd, "BUTTON", "Remove", WS_TABSTOP, IDC_REMOVE, 316, 282, 100, 28)
        AddCtl(hWnd, "BUTTON", "Skip code editors (VS Code, Visual Studio, JetBrains...)", CB, IDC_SKIPEDIT, 26, 362, 390, 22)
        AddCtl(hWnd, "BUTTON", "Skip terminals (Command Prompt, PowerShell, Windows Terminal...)", CB, IDC_SKIPTERM, 26, 386, 390, 22)
        AddCtl(hWnd, "BUTTON", "Skip fullscreen apps and games", CB, IDC_SKIPFULL, 26, 410, 390, 22)
        AddCtl(hWnd, "STATIC", "Password fields and apps running as administrator are always skipped.", SS_NOPREFIX, IDC_NOTE, 26, 438, 390, 34)
        ' ---
        AddCtl(hWnd, "BUTTON", "Close", BS_DEFPUSHBUTTON or WS_TABSTOP or WS_GROUP, IDOK, 336, 494, 92, 28)

        ' Slider positions are steps of DELAY_STEP ms; a tick every 100 ms
        dim as HWND sl = GetDlgItem(hWnd, IDC_SLIDER)
        SendMessage(sl, TBM_SETRANGE, TRUE, MAKELPARAM(DELAY_MIN \ DELAY_STEP, DELAY_MAX \ DELAY_STEP))
        SendMessage(sl, TBM_SETTICFREQ, 100 \ DELAY_STEP, 0)
        SendMessage(sl, TBM_SETLINESIZE, 0, 1)
        SendMessage(sl, TBM_SETPAGESIZE, 0, 100 \ DELAY_STEP)
        SettingsSync(hWnd)
        return 0

    case WM_COMMAND
        dim as long id = loword(wParam), code = hiword(wParam)
        select case id
        case IDC_ENABLED
            gEnabled = GetCheck(hWnd, IDC_ENABLED)
            gResetReq = 1
            TrayUpdate()
            SaveSettings()
        case IDC_AUTOSTART
            SetAutoStart(GetCheck(hWnd, IDC_AUTOSTART))
        case IDC_CLOSERS
            gAfterClosers = GetCheck(hWnd, IDC_CLOSERS)
            SaveSettings()
        case IDC_MODE_ALL, IDC_MODE_ONLY
            gOnlyListed = GetCheck(hWnd, IDC_MODE_ONLY)
            gCfgChanged = 1
            SettingsUpdateEnables(hWnd)
            SaveSettings()
        case IDC_SKIPEDIT, IDC_SKIPTERM, IDC_SKIPFULL
            gSkipEditors = GetCheck(hWnd, IDC_SKIPEDIT)
            gSkipTerminals = GetCheck(hWnd, IDC_SKIPTERM)
            gSkipFullscreen = GetCheck(hWnd, IDC_SKIPFULL)
            gCfgChanged = 1
            SaveSettings()
        case IDC_LIST
            if code = LBN_SELCHANGE then SettingsUpdateEnables(hWnd)
        case IDC_ADD
            SettingsShowAddMenu(hWnd)
        case IDC_REMOVE
            dim as long sel = SendDlgItemMessage(hWnd, IDC_LIST, LB_GETCURSEL, 0, 0)
            if sel >= 0 then
                SendDlgItemMessage(hWnd, IDC_LIST, LB_DELETESTRING, sel, 0)
                SettingsStoreList(hWnd)
                SettingsUpdateEnables(hWnd)
            end if
        case IDOK, IDCANCEL                 ' Close button, Enter, Esc
            DestroyWindow(hWnd)
        end select
        return 0

    case WM_HSCROLL
        if cast(HWND, lParam) = GetDlgItem(hWnd, IDC_SLIDER) then
            gDoubleTapMs = ClampDelay(SendDlgItemMessage(hWnd, IDC_SLIDER, TBM_GETPOS, 0, 0) * DELAY_STEP)
            SettingsUpdateSpeedLabel(hWnd)
            if loword(wParam) = TB_ENDTRACK then SaveSettings()
        end if
        return 0

    case WM_CTLCOLORSTATIC                  ' grey text for the small print
        dim as LRESULT br = DefWindowProc(hWnd, uMsg, wParam, lParam)
        select case GetDlgCtrlID(cast(HWND, lParam))
        case IDC_MINLBL, IDC_MAXLBL, IDC_NOTE
            SetTextColor(cast(HDC, wParam), GetSysColor(COLOR_GRAYTEXT))
        end select
        return br

    case WM_DPICHANGED                      ' moved to a monitor with other scaling
        dim as RECT ptr r = cast(RECT ptr, lParam)
        SettingsLayout(hWnd, loword(wParam), false, r->left, r->top)
        return 0

    case WM_DESTROY
        SaveSettings()
        if gSetFont then DeleteObject(gSetFont) : gSetFont = NULL
        hWndSettings = NULL
        return 0
    end select
    return DefWindowProc(hWnd, uMsg, wParam, lParam)
end function

sub ShowSettings()
    if hWndSettings then
        ShowWindow(hWndSettings, SW_RESTORE)
        SetForegroundWindow(hWndSettings)
        exit sub
    end if
    ' Created at the tray click point so it opens on that monitor, then centred
    hWndSettings = CreateWindowEx(0, @SETCLASS, "DblSpace Settings", SET_STYLE, _
                                  gMenuPt.x, gMenuPt.y, 100, 100, NULL, NULL, GetModuleHandle(NULL), NULL)
    if hWndSettings = NULL then exit sub
    SettingsLayout(hWndSettings, WindowDpi(hWndSettings), true, 0, 0)
    ShowWindow(hWndSettings, SW_SHOW)
    SetForegroundWindow(hWndSettings)
end sub

'==============================================================================
' Tray menu + hidden main window (main thread)
'==============================================================================
sub ShowTrayMenu(byval hWnd as HWND)
    ' Use the live cursor position. (GetMessagePos is wrong here: tray clicks
    ' are sent, not posted, so it returns the position from some older
    ' message - often far from the tray.)
    GetCursorPos(@gMenuPt)
    dim as long x = gMenuPt.x, y = gMenuPt.y

    dim as HMENU m = CreatePopupMenu()
    AppendMenu(m, MF_STRING, IDM_SETTINGS, "Settings...")
    AppendMenu(m, MF_SEPARATOR, 0, NULL)
    AppendMenu(m, MF_STRING, IDM_EXIT, "Exit")

    SetForegroundWindow(hWnd)           ' so the menu closes when you click away
    ' Open upward from the cursor like other tray menus (Windows flips it if
    ' the taskbar is at the top)
    TrackPopupMenu(m, TPM_RIGHTBUTTON or TPM_BOTTOMALIGN, x, y, 0, hWnd, NULL)
    PostMessage(hWnd, WM_NULL, 0, 0)
    DestroyMenu(m)
end sub

function WndProc stdcall (byval hWnd as HWND, byval uMsg as UINT, byval wParam as WPARAM, byval lParam as LPARAM) as LRESULT
    if uMsg = gTaskbarCreated andalso gTaskbarCreated <> 0 then
        TrayAddOrRetry()                ' Explorer restarted: re-add icon
        return 0
    end if

    select case uMsg
    case WM_TIMER
        if wParam = IDT_TRAYRETRY then TrayAddOrRetry()
        return 0

    case WM_FLUSH
        DoFlush()
        return 0

    case WM_TRAY
        if lParam = WM_RBUTTONUP orelse lParam = WM_LBUTTONUP then ShowTrayMenu(hWnd)
        return 0

    case WM_COMMAND
        select case loword(wParam)
        case IDM_SETTINGS
            ShowSettings()
        case IDM_EXIT
            DestroyWindow(hWnd)
        end select
        return 0

    case WM_DESTROY
        if hWndSettings then DestroyWindow(hWndSettings)
        Shell_NotifyIcon(NIM_DELETE, @nid)
        PostQuitMessage(0)
        return 0
    end select

    return DefWindowProc(hWnd, uMsg, wParam, lParam)
end function

'------------------------------------------------------------------------------
' Main
'------------------------------------------------------------------------------
dim as HANDLE hMutex = CreateMutex(NULL, TRUE, "DblSpace_SingleInstance")
if GetLastError() = ERROR_ALREADY_EXISTS then end 0     ' already running

#ifdef __FB_64BIT__
if sizeof(KbInput) <> 40 then
#else
if sizeof(KbInput) <> 28 then
#endif
    MessageBox(NULL, "INPUT struct size mismatch - check KbInput layout.", "DblSpace", MB_ICONERROR)
    end 1
end if

gOurIL = ProcessIL(GetCurrentProcess())
InitializeCriticalSection(@gCS)
InitializeCriticalSection(@gCfgCS)
gCheckReq  = CreateEvent(NULL, FALSE, FALSE, NULL)      ' auto-reset
gCheckDone = CreateEvent(NULL, TRUE, FALSE, NULL)       ' manual-reset
if AutoStartOn() then SetAutoStart(true)                ' refresh path if the exe moved
LoadSettings()

dim as HINSTANCE hInst = GetModuleHandle(NULL)
gTaskbarCreated = RegisterWindowMessage("TaskbarCreated")

dim as INITCOMMONCONTROLSEX icc
icc.dwSize = sizeof(icc)
icc.dwICC = ICC_BAR_CLASSES or ICC_STANDARD_CLASSES      ' slider, buttons, list
InitCommonControlsEx(@icc)

dim as WNDCLASSEX wc
wc.cbSize = sizeof(WNDCLASSEX)
wc.lpfnWndProc = @WndProc
wc.hInstance = hInst
wc.hIcon = LoadIcon(hInst, MAKEINTRESOURCE(IDI_ON))
wc.lpszClassName = @CLASSNAME
RegisterClassEx(@wc)

dim as WNDCLASSEX wcs
wcs.cbSize = sizeof(WNDCLASSEX)
wcs.lpfnWndProc = @SettingsProc
wcs.hInstance = hInst
wcs.hIcon = LoadIcon(hInst, MAKEINTRESOURCE(IDI_ON))
wcs.hIconSm = LoadImage(hInst, MAKEINTRESOURCE(IDI_ON), IMAGE_ICON, _
                        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0)
wcs.hCursor = LoadCursor(NULL, IDC_ARROW)
wcs.hbrBackground = cast(HBRUSH, COLOR_BTNFACE + 1)
wcs.lpszClassName = @SETCLASS
RegisterClassEx(@wcs)

' Hidden top-level window (not message-only, so it hears TaskbarCreated)
hWndMain = CreateWindowEx(0, @CLASSNAME, "DblSpace", 0, 0, 0, 0, 0, NULL, NULL, hInst, NULL)

CloseHandle(CreateThread(NULL, 0, cast(LPTHREAD_START_ROUTINE, @CheckerThread), NULL, 0, NULL))

dim as HANDLE hReady = CreateEvent(NULL, TRUE, FALSE, NULL)
dim as HANDLE hHookThread = CreateThread(NULL, 0, cast(LPTHREAD_START_ROUTINE, @HookThread), hReady, 0, @gHookTid)
WaitForSingleObject(hReady, 5000)
CloseHandle(hReady)
if gKbHook = NULL then
    MessageBox(NULL, "Could not install keyboard hook.", "DblSpace", MB_ICONERROR)
    end 1
end if

TrayAddOrRetry()

dim as MSG wmsg
while GetMessage(@wmsg, NULL, 0, 0) > 0
    ' Tab / Esc / Enter / arrow keys in the Settings window
    if hWndSettings andalso IsDialogMessage(hWndSettings, @wmsg) then continue while
    TranslateMessage(@wmsg)
    DispatchMessage(@wmsg)
wend

PostThreadMessage(gHookTid, WM_QUIT, 0, 0)
WaitForSingleObject(hHookThread, 1000)
CloseHandle(hMutex)
end 0
