Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$scriptPath = Join-Path $repoRoot 'backup.ps1'
. $scriptPath  # dot-source without executing main

Describe 'INI parsing and filters' {
  BeforeAll {
    $testDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ("WinBackupToUSB-" + [System.Guid]::NewGuid()))
    $iniPath = Join-Path $testDir 'backup.ini'
    @"
[General]
BackupName=TEST-BACKUP
DiskId=
AllowProceedNoSmart=yes

[Smart]
SmartOptions=-H
SmartOnEveryRun=yes

[Backup]
Src1=C:\\Data\\Docs
Src2=C:\\Data\\Pics
Include1=*.docx
Include2=*.xlsx
Exclude1=*.tmp
Exclude2=*.bak
ExcludeDir1=Cache
"@ | Set-Content -LiteralPath $iniPath -Encoding UTF8
  }

  It 'reads INI sections and keys' {
    $ini = Read-Ini -Path $iniPath
  ($ini.ContainsKey('General')) | Should Be $true
  ($ini['General']['BackupName']) | Should Be 'TEST-BACKUP'
  (Get-IniValue -Ini $ini -Section 'General' -Key 'NonExisting' -Default 'X') | Should Be 'X'
  }

  It 'updates INI values in-place' {
    Set-IniValue -Path $iniPath -Section 'General' -Key 'LastFullBackup' -Value '2025-10-10'
  $ini2 = Read-Ini -Path $iniPath
  ($ini2['General']['LastFullBackup']) | Should Be '2025-10-10'
  }

  It 'extracts backup sources (ignores filter keys)' {
    $ini = Read-Ini -Path $iniPath
    $sources = Get-BackupSources -Ini $ini
  ($sources -contains 'C:\\Data\\Docs') | Should Be $true
  ($sources -contains 'C:\\Data\\Pics') | Should Be $true
  ($sources -contains '*.docx') | Should Be $false
  }

  It 'extracts include/exclude filters' {
    $ini = Read-Ini -Path $iniPath
    $filters = Get-BackupFilters -Ini $ini
  ($filters.IncludeFiles -contains '*.docx') | Should Be $true
  ($filters.IncludeFiles -contains '*.xlsx') | Should Be $true
  ($filters.ExcludeFiles -contains '*.tmp') | Should Be $true
  ($filters.ExcludeFiles -contains '*.bak') | Should Be $true
  ($filters.ExcludeDirs  -contains 'Cache') | Should Be $true
  }

  AfterAll {
    if (Test-Path $testDir) { Remove-Item -Recurse -Force $testDir }
  }
}
