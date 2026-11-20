; Installer of ScriptWidget for Windows, for the copies published on GitHub Releases.
; Windows/scripts/installer.ps1 runs makensis with:
;   /DVERSION=0.1.0  /DARCH=x64|arm64  /DLAYOUT=<published program folder>
;   /DOUTPUT=<setup.exe>  /DICON=<ScriptWidget.ico>  /DFILELIST=<generated uninstall list>
;
; It installs for the current user only, without administrator rights, into
; %LOCALAPPDATA%\Programs\ScriptWidget. The program runs without a package identity there:
; its data is in %LOCALAPPDATA%\ScriptWidget and "Start when I sign in" uses the Run key.

Unicode true
ManifestDPIAware true
RequestExecutionLevel user
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"
!include "WinVer.nsh"

!define APP "ScriptWidget"
!define PUBLISHER "AtomSprout"
!define WEBSITE "https://atomsprout.com/scriptwidget/"
!define UNINSTALL_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP}"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"
!define FILE_CLASS "ScriptWidget.Package"

Name "${APP}"
OutFile "${OUTPUT}"
InstallDir "$LOCALAPPDATA\Programs\${APP}"
BrandingText "${APP} ${VERSION} (${ARCH})"
ShowInstDetails nevershow
ShowUninstDetails nevershow

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP} Setup"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "${PUBLISHER}"

!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\ScriptWidgetStudio.exe"
!define MUI_FINISHPAGE_RUN_TEXT "$(RunText)"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

LangString RunText ${LANG_ENGLISH} "Open ScriptWidget"
LangString NeedsWindows11 ${LANG_ENGLISH} "ScriptWidget needs Windows 11."
LangString WrongProcessor ${LANG_ENGLISH} "This installer is for ${ARCH} computers. Download the installer that matches this computer."
LangString StillRunning ${LANG_ENGLISH} "ScriptWidget is still running and could not be closed. Quit it from its tray icon, then try again."
LangString RemoveData ${LANG_ENGLISH} "Also delete your widgets and settings?$\r$\n$\r$\nThey are kept in $LOCALAPPDATA\${APP}. Choose No to keep them for a later installation."
LangString FileTypeName ${LANG_ENGLISH} "ScriptWidget package"

; Stops the copy of the program that runs from $INSTDIR, and no other: a copy installed from the
; Microsoft Store has the same process names. The host is asked to quit and is given five seconds,
; the management window is asked to close; what is left after that is ended.
; The folder is passed in an environment variable so that no path is ever part of the script text.
; (Kept short: a string in an installer script holds at most 1024 characters. M lists the processes
; of this copy by name pattern, W waits up to five seconds for them to be gone.)
!define CLOSE_SCRIPT "if(-not $$env:SCRIPTWIDGET_SETUP_DIR){exit 2};$$d=$$env:SCRIPTWIDGET_SETUP_DIR.TrimEnd('\')+'\';function M($$n){gps $$n -ea 0|?{$$_.Path -and $$_.Path.StartsWith($$d,'OrdinalIgnoreCase')}};function W{foreach($$i in 1..20){if(-not(M ScriptWidget*)){return $$true};sleep -m 250};$$false};if(M ScriptWidget){&($$d+'ScriptWidget.exe') --quit|Out-Null};M ScriptWidgetStudio|%{$$null=$$_.CloseMainWindow()};$$null=W;M ScriptWidget*|kill -Force;if(W){exit 0};exit 1"

!macro CloseRunning
  System::Call 'Kernel32::SetEnvironmentVariable(t, t)i ("SCRIPTWIDGET_SETUP_DIR", "$INSTDIR").r0'
  ; In backticks: the script has single quotes of its own. The 64-bit PowerShell (Sysnative): the
  ; installer is a 32-bit program, and a 32-bit PowerShell cannot read the path of a 64-bit process.
  nsExec::Exec `"$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "${CLOSE_SCRIPT}"`
  Pop $0
  ${If} $0 != 0
    MessageBox MB_OK|MB_ICONEXCLAMATION "$(StillRunning)" /SD IDOK
    Abort
  ${EndIf}
!macroend

Function .onInit
  ${IfNot} ${AtLeastWin10}
    MessageBox MB_OK|MB_ICONSTOP "$(NeedsWindows11)" /SD IDOK
    Abort
  ${EndIf}
  ${If} ${AtMostBuild} 21999
    MessageBox MB_OK|MB_ICONSTOP "$(NeedsWindows11)" /SD IDOK
    Abort
  ${EndIf}
!if "${ARCH}" == "arm64"
  ${IfNot} ${IsNativeARM64}
    MessageBox MB_OK|MB_ICONSTOP "$(WrongProcessor)" /SD IDOK
    Abort
  ${EndIf}
!else
  ; An x64 build also runs on ARM64, where Windows 11 emulates it.
  ${IfNot} ${IsNativeAMD64}
  ${AndIfNot} ${IsNativeARM64}
    MessageBox MB_OK|MB_ICONSTOP "$(WrongProcessor)" /SD IDOK
    Abort
  ${EndIf}
!endif
FunctionEnd

Section "Install"
  !insertmacro CloseRunning
  ; An update: files of the earlier version that the new one no longer has must not stay behind.
  ${If} ${FileExists} "$INSTDIR\uninstall.exe"
    !include "${FILELIST}"
  ${EndIf}

  SetOutPath "$INSTDIR"
  ; The package manifest belongs to the MSIX form only.
  File /r /x "AppxManifest.xml" "${LAYOUT}\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  CreateShortcut "$SMPROGRAMS\${APP}.lnk" "$INSTDIR\ScriptWidgetStudio.exe"

  ; Widget packages (.swt) open in the management window, which reviews them before importing.
  WriteRegStr HKCU "Software\Classes\.swt" "" "${FILE_CLASS}"
  WriteRegStr HKCU "Software\Classes\${FILE_CLASS}" "" "$(FileTypeName)"
  WriteRegStr HKCU "Software\Classes\${FILE_CLASS}\DefaultIcon" "" "$INSTDIR\ScriptWidgetStudio.exe,0"
  WriteRegStr HKCU "Software\Classes\${FILE_CLASS}\shell\open\command" "" '"$INSTDIR\ScriptWidgetStudio.exe" "%1"'

  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "URLInfoAbout" "${WEBSITE}"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "DisplayIcon" "$INSTDIR\ScriptWidgetStudio.exe,0"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTALL_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINSTALL_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINSTALL_KEY}" "EstimatedSize" ${SIZE_KB}

  ; Tell the shell that a file type changed.
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'
SectionEnd

Section "Uninstall"
  !insertmacro CloseRunning

  ; Only what the installer put there is removed, by name: the folder itself is removed only when
  ; nothing else is left in it.
  !include "${FILELIST}"
  ; The code editor's browser profile, which the management window creates beside itself.
  RMDir /r "$INSTDIR\ScriptWidgetStudio.exe.WebView2"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\${APP}.lnk"

  ; "Start when I sign in", when it points at this copy.
  ReadRegStr $0 HKCU "${RUN_KEY}" "${APP}"
  ${If} $0 == '"$INSTDIR\ScriptWidget.exe" --startup'
    DeleteRegValue HKCU "${RUN_KEY}" "${APP}"
  ${EndIf}

  ; The file type, when it still points at this program.
  ReadRegStr $0 HKCU "Software\Classes\.swt" ""
  ${If} $0 == "${FILE_CLASS}"
    DeleteRegValue HKCU "Software\Classes\.swt" ""
    DeleteRegKey /ifempty HKCU "Software\Classes\.swt"
  ${EndIf}
  DeleteRegKey HKCU "Software\Classes\${FILE_CLASS}"
  DeleteRegKey HKCU "${UNINSTALL_KEY}"
  System::Call 'shell32::SHChangeNotify(i 0x08000000, i 0, p 0, p 0)'

  ; The user's widgets and settings stay unless the user says otherwise; a silent uninstall keeps them.
  MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "$(RemoveData)" /SD IDNO IDNO keep
    RMDir /r "$LOCALAPPDATA\${APP}"
  keep:
SectionEnd
