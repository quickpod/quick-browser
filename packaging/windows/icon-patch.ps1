# icon-patch.ps1 — replace a PE file's main icon GROUP with a multi-res .ico.
#
#   powershell -ExecutionPolicy Bypass -File icon-patch.ps1 `
#     -Exe chrome.exe -Ico quick-browser.ico -GroupName IDR_MAINFRAME [-BaseId 901]
#
# WHY NOT rcedit: rcedit 2.0 (native or under wine) swaps the RT_ICON data
# blobs behind the FIRST group but never rewrites the RT_GROUP_ICON directory,
# so when the target's group layout differs from the .ico (chrome.exe has 7
# entries, three of them low-colour), the dimension->data mapping is garbage
# and any frame beyond the .ico's count (chrome's 256px PNG!) survives
# untouched. This script does what the platform intends: it writes the .ico's
# frames as NEW RT_ICON resources (BaseId..) and rebuilds the named group's
# GRPICONDIR to reference exactly those, via BeginUpdateResource /
# UpdateResource / EndUpdateResource. Old RT_ICON blobs become unreferenced
# (harmless); every other icon group in the file is untouched.
#
# Must run on real Windows (the resource-update APIs rewrite the PE .rsrc
# section; wine's implementation is not trustworthy for this).
#
# NOTE: rewriting a resource invalidates any Authenticode signature on the
# file — re-sign afterwards (we re-sign with the QuickOpen Root CA).
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [Parameter(Mandatory=$true)][string]$Ico,
  [Parameter(Mandatory=$true)][string]$GroupName,  # "IDR_MAINFRAME" or "#32512"
  [int]$BaseId = 901,
  [int]$Lang = 1033
)
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ResUpdate {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern IntPtr BeginUpdateResourceW(string pFileName, bool bDeleteExistingResources);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool UpdateResourceW(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool UpdateResourceW(IntPtr hUpdate, IntPtr lpType, string lpName, ushort wLanguage, byte[] lpData, uint cbData);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool EndUpdateResourceW(IntPtr hUpdate, bool fDiscard);
}
"@

$RT_ICON = [IntPtr]3
$RT_GROUP_ICON = [IntPtr]14

# NB: PowerShell variables are case-insensitive — the byte buffer must NOT
# be called $ico or it aliases the [string]$Ico parameter and gets stringified.
$icoBytes = [System.IO.File]::ReadAllBytes((Resolve-Path $Ico))
if ([BitConverter]::ToUInt16($icoBytes, 2) -ne 1) { throw "$Ico is not an .ico" }
$count = [BitConverter]::ToUInt16($icoBytes, 4)
if ($count -lt 1) { throw "$Ico has no images" }

$h = [ResUpdate]::BeginUpdateResourceW((Resolve-Path $Exe), $false)
if ($h -eq [IntPtr]::Zero) { throw "BeginUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

# GRPICONDIR: 6-byte header + 14 bytes per entry (the .ico's 16-byte entries
# with the dword file-offset swapped for a word resource id).
$grp = New-Object System.IO.MemoryStream
$grp.Write($icoBytes, 0, 6)                    # idReserved, idType, idCount
for ($i = 0; $i -lt $count; $i++) {
  $e = 6 + 16 * $i
  $size   = [BitConverter]::ToUInt32($icoBytes, $e + 8)
  $offset = [BitConverter]::ToUInt32($icoBytes, $e + 12)
  $frame = New-Object byte[] $size
  [Array]::Copy($icoBytes, $offset, $frame, 0, $size)
  $id = $BaseId + $i
  if (-not [ResUpdate]::UpdateResourceW($h, $RT_ICON, [IntPtr]$id, [uint16]$Lang, $frame, [uint32]$size)) {
    [ResUpdate]::EndUpdateResourceW($h, $true) | Out-Null
    throw "UpdateResource RT_ICON $id failed"
  }
  $grp.Write($icoBytes, $e, 12)                # width,height,colors,reserved,planes,bpp,bytesInRes
  $idBytes = [BitConverter]::GetBytes([uint16]$id)
  $grp.Write($idBytes, 0, 2)
  Write-Output ("  frame {0}: {1}x{2} {3} B -> RT_ICON #{4}" -f $i, $icoBytes[$e], $icoBytes[$e+1], $size, $id)
}
$blob = $grp.ToArray()

$ok = $false
if ($GroupName.StartsWith('#')) {
  $gid = [int]$GroupName.Substring(1)
  $ok = [ResUpdate]::UpdateResourceW($h, $RT_GROUP_ICON, [IntPtr]$gid, [uint16]$Lang, $blob, [uint32]$blob.Length)
} else {
  $ok = [ResUpdate]::UpdateResourceW($h, $RT_GROUP_ICON, [string]$GroupName, [uint16]$Lang, $blob, [uint32]$blob.Length)
}
if (-not $ok) { [ResUpdate]::EndUpdateResourceW($h, $true) | Out-Null; throw "UpdateResource RT_GROUP_ICON $GroupName failed" }
if (-not [ResUpdate]::EndUpdateResourceW($h, $false)) { throw "EndUpdateResource failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
Write-Output ("OK: {0} icon group '{1}' now has {2} frames from {3}" -f $Exe, $GroupName, $count, $Ico)
