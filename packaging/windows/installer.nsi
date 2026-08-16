; Quick Browser — Windows installer (NSIS).
;
; v1 POLICY: this REPACKAGES the official ungoogled-chromium Windows build
; (see windows-pin.txt) with QuickOpen branding — shortcuts, icon, default-
; browser registration, licences. The Linux deb is a from-source build; a
; Windows source build is a later phase. The upstream payload binaries are
; shipped byte-identical (their own signatures, where present, are not
; touched); only this OUTER installer is ours.
;
; Compiled with makensis on Linux:
;   makensis -DPAYLOAD=<dir> -DVERSION=<chromium-ver> -DDISPLAYVERSION=<ver-rev> \
;            -DESTSIZE_KB=<du -sk> -DOUTFILE=<path> installer.nsi
;
; Supports silent install/uninstall with /S. Installs machine-wide (admin).

Unicode true
!include "MUI2.nsh"
; WinShell plug-in (pinned in windows-pin.txt): sets the AppUserModelID on the
; shortcuts so taskbar pins/grouping bind to the running browser, which itself
; runs under Chromium's base AUMID.
!addplugindir "${PLUGINDIR}"

!define APPNAME "Quick Browser"
!define APPKEY  "QuickBrowser"
!define PUBLISHER "QuickOpen"
!define APPURL "https://quickopen.ai/projects/quick-browser"
!define AUMID "Chromium"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APPKEY}"

Name "${APPNAME}"
OutFile "${OUTFILE}"
InstallDir "$PROGRAMFILES64\QuickOpen\${APPNAME}"
RequestExecutionLevel admin
; the outer installer gets Authenticode-signed after the build; the appended
; signature would invalidate the NSIS CRC, so integrity rides on the signature
CRCCheck off
SetCompressor /SOLID lzma
SetCompressorDictSize 64
SetDatablockOptimize on

VIProductVersion "${VERSION}"
VIAddVersionKey "ProductName" "${APPNAME}"
VIAddVersionKey "CompanyName" "${PUBLISHER}"
VIAddVersionKey "ProductVersion" "${DISPLAYVERSION}"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "${APPNAME} installer"
VIAddVersionKey "LegalCopyright" "Engine: BSD-3-Clause (Chromium + ungoogled-chromium). QuickOpen layer: Apache-2.0."

!define MUI_ICON "${ICOFILE}"
!define MUI_UNICON "${ICOFILE}"
!insertmacro MUI_PAGE_LICENSE "${LICENSEFILE}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Section "Quick Browser"
  SetRegView 64
  SetShellVarContext all
  SetOutPath "$INSTDIR"

  ; upstream payload, byte-identical
  File /r "${PAYLOAD}/*"

  ; our branding + licences
  File "${ICOFILE}"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; shortcuts — Quick name + Quick icon
  CreateShortCut "$SMPROGRAMS\${APPNAME}.lnk" "$INSTDIR\chrome.exe" "" "$INSTDIR\quick-browser.ico" 0 SW_SHOWNORMAL "" "A fast web browser with the Google removed"
  CreateShortCut "$DESKTOP\${APPNAME}.lnk" "$INSTDIR\chrome.exe" "" "$INSTDIR\quick-browser.ico" 0
  ; bind the shortcuts to the AUMID the running browser reports (Chromium's
  ; base app id) so the taskbar groups them with our embedded window icon
  WinShell::SetLnkAUMI "$SMPROGRAMS\${APPNAME}.lnk" "${AUMID}"
  WinShell::SetLnkAUMI "$DESKTOP\${APPNAME}.lnk" "${AUMID}"

  ; uninstall entry
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayName" "${APPNAME}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayVersion" "${DISPLAYVERSION}"
  WriteRegStr HKLM "${UNINSTKEY}" "Publisher" "${PUBLISHER}"
  WriteRegStr HKLM "${UNINSTKEY}" "DisplayIcon" "$INSTDIR\quick-browser.ico"
  WriteRegStr HKLM "${UNINSTKEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINSTKEY}" "URLInfoAbout" "${APPURL}"
  WriteRegStr HKLM "${UNINSTKEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegStr HKLM "${UNINSTKEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "NoRepair" 1
  WriteRegDWORD HKLM "${UNINSTKEY}" "EstimatedSize" ${ESTSIZE_KB}

  ; default-browser capability (Settings > Default apps), named Quick Browser
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}" "" "${APPNAME}"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\DefaultIcon" "" "$INSTDIR\quick-browser.ico,0"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\shell\open\command" "" '"$INSTDIR\chrome.exe"'
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities" "ApplicationName" "${APPNAME}"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities" "ApplicationDescription" "A fast web browser with the Google removed — no telemetry, nothing phoning home."
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities" "ApplicationIcon" "$INSTDIR\quick-browser.ico,0"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities\StartMenu" "StartMenuInternet" "${APPKEY}"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities\URLAssociations" "http" "${APPKEY}HTML"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities\URLAssociations" "https" "${APPKEY}HTML"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities\FileAssociations" ".htm" "${APPKEY}HTML"
  WriteRegStr HKLM "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities\FileAssociations" ".html" "${APPKEY}HTML"
  WriteRegStr HKLM "Software\Classes\${APPKEY}HTML" "" "${APPNAME} HTML Document"
  WriteRegStr HKLM "Software\Classes\${APPKEY}HTML\DefaultIcon" "" "$INSTDIR\quick-browser.ico,0"
  WriteRegStr HKLM "Software\Classes\${APPKEY}HTML\shell\open\command" "" '"$INSTDIR\chrome.exe" -- "%1"'
  WriteRegStr HKLM "Software\RegisteredApplications" "${APPNAME}" "Software\Clients\StartMenuInternet\${APPKEY}\Capabilities"
SectionEnd

Section "Uninstall"
  SetRegView 64
  SetShellVarContext all
  Delete "$SMPROGRAMS\${APPNAME}.lnk"
  Delete "$DESKTOP\${APPNAME}.lnk"
  DeleteRegValue HKLM "Software\RegisteredApplications" "${APPNAME}"
  DeleteRegKey HKLM "Software\Classes\${APPKEY}HTML"
  DeleteRegKey HKLM "Software\Clients\StartMenuInternet\${APPKEY}"
  DeleteRegKey HKLM "${UNINSTKEY}"
  ; user profiles (%LOCALAPPDATA%\Chromium) are the user's and are left alone
  RMDir /r "$INSTDIR"
SectionEnd
