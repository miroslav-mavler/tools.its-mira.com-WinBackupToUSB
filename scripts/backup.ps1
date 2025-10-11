<#
	Backup to USB script (skeleton)

	Goals:
	- Uses INI config (backup.ini) with sections: [General], [Smart], [Backup]
	- Stores unique DiskId on first run if empty
	- Full backup on first run; otherwise incremental
	- Force full backup if last full > 90 days, with user prompt to run now or postpone (max 3)
	- Optional SMART health check using smartctl if available

	Assumptions:
	- The script is located on the target USB drive, or the USB drive is mounted and writable
	- [Backup] section lists source directories as key=value (any key), e.g. Src1=C:\Users\Mira\Documents
	- Destination layout: <USB>:\<BackupName>\<leaf of source> (per source)
	- We append/update only our keys in the INI to avoid reformatting other content
	- Requires robocopy (built into Windows)

	Keys we add in [General]:
		LastFullBackup=yyyy-MM-dd
		FullBackupPostpones=0..3

	Example INI:
		[General]
		BackupName=ITS-MIRA-Backup
		DiskId=
		AllowProceedNoSmart=yes

		[Smart]
		SmartOptions=-H
		SmartOnEveryRun=yes

		[Backup]
		Src1=C:\Users\Mira\Documents
		Src2=C:\Users\Mira\Pictures
#>

[CmdletBinding()]
param(
	[string]$ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath 'backup.ini'),
	[switch]$Full,
	[switch]$WhatIf,
	[switch]$NoGui,
	[switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Ini {
	param([string]$Path)
	if (!(Test-Path -LiteralPath $Path)) { throw "Config not found: $Path" }
	$ini = @{}
	$current = ''
	Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object {
		$line = $_.Trim()
		if ($line -match '^(;|#)' -or [string]::IsNullOrWhiteSpace($line)) { return }
		if ($line -match '^\[(?<sec>[^\]]+)\]$') {
			$current = $Matches['sec']
			if (-not $ini.ContainsKey($current)) { $ini[$current] = @{} }
		} elseif ($line -match '^(?<k>[^=]+)=(?<v>.*)$') {
			if (-not $ini.ContainsKey($current)) { $ini[$current] = @{} }
			$k = $Matches['k'].Trim()
			$v = $Matches['v']
			$ini[$current][$k] = $v
		}
	}
	return $ini
}

function Set-IniValue {
	param(
		[string]$Path,
		[string]$Section,
		[string]$Key,
		[string]$Value
	)
	$lines = @()
	if (Test-Path -LiteralPath $Path) {
		$lines = Get-Content -LiteralPath $Path -Encoding UTF8
	}
	$out = New-Object System.Collections.Generic.List[string]
	$inSection = $false
	$foundSection = $false
	$keyUpdated = $false
	for ($i=0; $i -lt $lines.Count; $i++) {
		$line = $lines[$i]
		if ($line -match '^\[(?<sec>[^\]]+)\]$') {
			if ($inSection -and -not $keyUpdated) {
				$out.Add("$Key=$Value")
				$keyUpdated = $true
			}
			$inSection = ($Matches['sec'] -eq $Section)
			if ($inSection) { $foundSection = $true }
			$out.Add($line)
			continue
		}
		if ($inSection -and $line -match '^(?<k>[^=]+)=(?<v>.*)$') {
			if ($Matches['k'].Trim() -eq $Key) {
				$out.Add("$Key=$Value")
				$keyUpdated = $true
				continue
			}
		}
		$out.Add($line)
	}
	if (-not $foundSection) {
		if ($out.Count -gt 0 -and $out[$out.Count-1].Trim() -ne '') { $out.Add('') }
		$out.Add("[$Section]")
		$out.Add("$Key=$Value")
	} elseif ($inSection -and -not $keyUpdated) {
		$out.Add("$Key=$Value")
	}
	$out | Set-Content -LiteralPath $Path -Encoding UTF8 -NoNewline:$false
}

function Get-IniValue {
	param([hashtable]$Ini, [string]$Section, [string]$Key, [string]$Default = '')
	if ($Ini.ContainsKey($Section) -and $Ini[$Section].ContainsKey($Key)) { return $Ini[$Section][$Key] }
	return $Default
}

function Get-TargetDriveInfo {
	param([string]$DriveLetter)
	# Determine target drive letter
	$driveLetter = $null
	if ($PSBoundParameters.ContainsKey('DriveLetter') -and $DriveLetter) {
		$driveLetter = $DriveLetter.TrimEnd(':', '\')
	} else {
		# Fallback to script location drive letter
		$driveLetter = (Split-Path -Qualifier -Path $PSScriptRoot).TrimEnd(':', '\')
	}
	if (-not $driveLetter) { throw 'Unable to determine target drive letter from script path.' }

	$vol = $null
	try { $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop } catch {}
	$part = $null
	try { $part = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop } catch {}
	$disk = $null
	if ($part) { try { $disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop } catch {} }

	$idCandidates = @()
	if ($vol -and $vol.UniqueId) { $idCandidates += $vol.UniqueId }
	if ($disk -and $disk.SerialNumber) { $idCandidates += $disk.SerialNumber }
	if ($part -and $part.Guid) { $idCandidates += $part.Guid }
	# Fallback: Volume Serial Number from fsutil
		try {
			$volPath = ("${driveLetter}:\\")
			$fs = (fsutil fsinfo volumeinfo $volPath 2>$null)
			$vsn = ($fs | Select-String -Pattern 'Serial Number is ([0-9A-F-]+)')
			if ($vsn) { $idCandidates += ($vsn.Matches[0].Groups[1].Value) }
		} catch {}
	$uniqueId = ($idCandidates | Where-Object { $_ } | Select-Object -First 1)
		$devicePath = $null
		if ($disk -and $disk.Number -ge 0) { $devicePath = "\\.\PhysicalDrive$($disk.Number)" }
	return [pscustomobject]@{
		DriveLetter = $driveLetter
		Volume      = $vol
		Partition   = $part
		Disk        = $disk
		UniqueId    = $uniqueId
        DevicePath  = $devicePath
	}
}

function Get-SystemDiskNumber {
	try {
		$sysDrive = [Environment]::GetEnvironmentVariable('SystemDrive')
		if (-not $sysDrive) { $sysDrive = 'C:' }
		$dl = $sysDrive.TrimEnd(':', '\').Trim()
		$sysPart = Get-Partition -DriveLetter $dl -ErrorAction Stop | Select-Object -First 1
		return $sysPart.DiskNumber
	} catch { return $null }
}

function Get-TotalSourceBytes {
	param([string[]]$Sources)
	[Int64]$total = 0
	foreach ($s in $Sources) {
		if (Test-Path -LiteralPath $s) {
			try {
				$total += (Get-ChildItem -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Measure-Object Length -Sum).Sum
			} catch {}
		}
	}
	return $total
}

function Show-ChoiceDialog3 {
	param(
		[string]$Message,
		[string]$Title,
		[switch]$NoGui
	)
	if (-not $NoGui) {
		try {
			Add-Type -AssemblyName PresentationFramework -ErrorAction Stop | Out-Null
			$buttons = [System.Windows.MessageBoxButton]::YesNoCancel
			$icon = [System.Windows.MessageBoxImage]::Question
			$res = [System.Windows.MessageBox]::Show($Message, $Title, $buttons, $icon)
			switch ($res) {
				'Yes' { return 'Yes' }
				'No' { return 'No' }
				default { return 'Cancel' }
			}
		} catch {}
	}
	Write-Host $Title -ForegroundColor Yellow
	Write-Host $Message -ForegroundColor Yellow
	while ($true) {
		$ans = Read-Host 'Volba [Y]=Ano, [N]=Ne, [C]=Zrušit'
		if ($ans -match '^(?i:y|yes)$') { return 'Yes' }
		if ($ans -match '^(?i:n|no)$') { return 'No' }
		if ($ans -match '^(?i:c|cancel)$') { return 'Cancel' }
	}
}

function Select-BackupVolume {
	param([switch]$NoGui)
	$sysDisk = Get-SystemDiskNumber
	$volumes = @()
	foreach ($v in (Get-Volume | Where-Object { $_.DriveLetter })) {
		try {
			$p = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction Stop
			$d = Get-Disk -Number $p.DiskNumber -ErrorAction Stop
			if ($null -ne $sysDisk -and $d.Number -eq $sysDisk) { continue }
			if ($v.FileSystem -and $v.DriveType -ne 'CD-ROM') {
				$volumes += [pscustomobject]@{
					Index       = 0
					DriveLetter = $v.DriveLetter
					Label       = $v.FileSystemLabel
					FileSystem  = $v.FileSystem
					Size        = $v.Size
					Free        = $v.SizeRemaining
					DiskNumber  = $d.Number
					DiskBus     = $d.BusType
					DiskName    = $d.FriendlyName
				}
			}
		} catch {}
	}
	if ($volumes.Count -eq 0) { throw 'Nebyly nalezeny vhodné svazky na jiném fyzickém disku než systémovém. Připojte externí disk a zkuste to znovu.' }
	for ($i=0; $i -lt $volumes.Count; $i++) { $volumes[$i].Index = $i }
	Write-Host 'Vyberte cílový svazek pro zálohu (na jiném fyzickém disku než systémový):' -ForegroundColor Cyan
	foreach ($it in $volumes) {
		$sizeGB = [Math]::Round($it.Size/1GB, 1)
		$freeGB = [Math]::Round($it.Free/1GB, 1)
		Write-Host ("[$($it.Index)] Disk #$($it.DiskNumber) ($($it.DiskBus)) $($it.DiskName)  $($it.DriveLetter):  FS=$($it.FileSystem)  Label='$($it.Label)'  Free=$freeGB GB / $sizeGB GB")
	}
	while ($true) {
		$sel = Read-Host 'Zadejte číslo volby'
		if ($sel -match '^\d+$') {
			$idx = [int]$sel
			if ($idx -ge 0 -and $idx -lt $volumes.Count) { return $volumes[$idx] }
		}
	}
}

function Initialize-BackupTarget {
	param(
		[hashtable]$Ini,
		[string]$ConfigPath,
		[string]$BackupName,
		[string[]]$Sources,
		[switch]$NoGui,
		[switch]$Silent
	)
	if ($Silent) { throw 'Prvotní výběr cílového disku vyžaduje interaktivní režim.' }
	$sysDisk = Get-SystemDiskNumber
	if ($null -ne $sysDisk) { Write-Host "Systémový fyzický disk: #$sysDisk" -ForegroundColor DarkGray }
	Write-Host 'Ochrana: nelze vybrat systémový disk ani jiný oddíl na stejném fyzickém disku.' -ForegroundColor Yellow
	$choice = Select-BackupVolume -NoGui:$NoGui
	$driveLetter = [string]$choice.DriveLetter

	# Optional SMART check of selected disk
	$smartOpts = (Get-IniValue -Ini $Ini -Section 'Smart' -Key 'SmartOptions' -Default '-H')
	try {
		$tgt = Get-TargetDriveInfo -DriveLetter $driveLetter
		if ($tgt.DevicePath) {
			$ok = Test-SmartHealth -SmartOptions $smartOpts -DevicePath $tgt.DevicePath -Quiet
			if (-not $ok) { Write-Warning 'SMART test hlásí problémy na vybraném disku.' }
		}
	} catch {}

	# Capacity checks
	$totalBytes = Get-TotalSourceBytes -Sources $Sources
	$freeBytes = [Int64]$choice.Free
	if ($totalBytes -eq 0) { Write-Host 'Pozor: zdrojová data nelze spočítat, pokračuji.' -ForegroundColor Yellow }
	if ($totalBytes -gt 0 -and $freeBytes -lt $totalBytes) {
		throw ("Na cílovém svazku ($($driveLetter):) není dostatek volného místa. Potřeba ~{0} GB, k dispozici ~{1} GB." -f [Math]::Round($totalBytes/1GB,2), [Math]::Round($freeBytes/1GB,2))
	}
	# Filesystem suitability
	$fs = $choice.FileSystem
	$fsOk = $false
	switch ($fs) { 'NTFS' { $fsOk = $true } 'exFAT' { $fsOk = $true } default { $fsOk = $false } }
	if (-not $fsOk) { Write-Warning "Souborový systém '$fs' není ideální (doporučeno NTFS/exFAT)." }

	# Prepare Instance identifiers
	$instanceId = (Get-IniValue -Ini $Ini -Section 'General' -Key 'InstanceId' -Default '')
	if (-not $instanceId) { $instanceId = ([guid]::NewGuid().ToString('N')) }
	$instanceFolder = (Get-IniValue -Ini $Ini -Section 'General' -Key 'InstanceFolder' -Default '')
	if (-not $instanceFolder) { $instanceFolder = ("{0}_{1}_{2}" -f $env:COMPUTERNAME, $env:USERNAME, $instanceId) }

	# Persist selection into INI
	Set-IniValue -Path $ConfigPath -Section 'General' -Key 'TargetDriveLetter' -Value $driveLetter
	Set-IniValue -Path $ConfigPath -Section 'General' -Key 'InstanceId' -Value $instanceId
	Set-IniValue -Path $ConfigPath -Section 'General' -Key 'InstanceFolder' -Value $instanceFolder

	# Also persist instance id to registry (HKCU)
	try {
		$regPath = 'HKCU:Software/its-mira/WinBackupToUSB'
		if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
		New-ItemProperty -Path $regPath -Name 'InstanceId' -Value $instanceId -PropertyType String -Force | Out-Null
	} catch {}

	# Capture DiskId for selected target disk
	try {
		$part = Get-Partition -DriveLetter $driveLetter -ErrorAction Stop
		$disk = Get-Disk -Number $part.DiskNumber -ErrorAction Stop
		$diskId = if ($disk.SerialNumber) { $disk.SerialNumber } else { $disk.UniqueId }
		if ($diskId) { Set-IniValue -Path $ConfigPath -Section 'General' -Key 'DiskId' -Value $diskId }
	} catch {}

	# Create destination instance folder and marker
	$destRoot = Join-Path -Path ("$($driveLetter):\") -ChildPath $BackupName
	$destRoot = Join-Path -Path $destRoot -ChildPath $instanceFolder
	if (!(Test-Path -LiteralPath $destRoot)) { New-Item -ItemType Directory -Path $destRoot -Force | Out-Null }
	$marker = Join-Path -Path $destRoot -ChildPath '.backup-id.txt'
	$markerContent = @(
		"InstanceId=$instanceId",
		"Computer=$($env:COMPUTERNAME)",
		"User=$($env:USERNAME)",
		"Created=$(Get-Date -Format o)"
	) -join [Environment]::NewLine
	$markerContent | Set-Content -LiteralPath $marker -Encoding UTF8

	# Ask user for format-before-backup and proceed
	$msg = @()
	$msg += "Vybrán svazek $($driveLetter):, Disk #$($choice.DiskNumber) ($($choice.DiskBus))."
	if ($totalBytes -gt 0) { $msg += ("Odhad velikosti dat: ~{0} GB." -f [Math]::Round($totalBytes/1GB,2)) }
	$msg += ("Volné místo: ~{0} GB." -f [Math]::Round($freeBytes/1GB,2))
	$msg += "Souborový systém: $fs."
	if (-not $fsOk) { $msg += "Doporučeno disk přeformátovat na NTFS." }
	$msg += ''
	$msg += 'Chcete:'
	$msg += ' - [Ano] Disk NAFORMATOVAT (NTFS) a spustit první PLNOU zálohu'
	$msg += ' - [Ne]  Spustit první PLNOU zálohu bez formátování'
	$msg += ' - [Zrušit] Ukončit bez spuštění zálohy'
	$res = Show-ChoiceDialog3 -Message ($msg -join [Environment]::NewLine) -Title 'Inicializace cílového disku' -NoGui:$NoGui
	switch ($res) {
		'Yes' { return [pscustomobject]@{ DriveLetter=$driveLetter; InstanceFolder=$instanceFolder; ProceedBackup=$true; FormatBefore=$true } }
		'No'  { return [pscustomobject]@{ DriveLetter=$driveLetter; InstanceFolder=$instanceFolder; ProceedBackup=$true; FormatBefore=$false } }
		default { return [pscustomobject]@{ DriveLetter=$driveLetter; InstanceFolder=$instanceFolder; ProceedBackup=$false; FormatBefore=$false } }
	}
}

function Format-BackupVolume {
	param([Parameter(Mandatory)][string]$DriveLetter)
	$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
	if (-not $isAdmin) { throw 'Formátování vyžaduje spuštění PowerShellu jako správce (Run as Administrator).' }
	try {
	Write-Warning "Formátuji $($DriveLetter): na NTFS. POZOR: všechna data na tomto svazku budou smazána!"
		Format-Volume -DriveLetter $DriveLetter -FileSystem NTFS -Confirm:$false -Force | Out-Null
	} catch { throw "Formátování se nezdařilo: $($_.Exception.Message)" }
}

function Write-InstanceMarker {
	param([string]$DestRoot, [hashtable]$Ini)
	if (-not (Test-Path -LiteralPath $DestRoot)) { return }
	$marker = Join-Path -Path $DestRoot -ChildPath '.backup-id.txt'
	if (Test-Path -LiteralPath $marker) { return }
	$instanceId = (Get-IniValue -Ini $Ini -Section 'General' -Key 'InstanceId' -Default '')
	if (-not $instanceId) { $instanceId = ([guid]::NewGuid().ToString('N')) }
	try {
		$regPath = 'HKCU:Software/its-mira/WinBackupToUSB'
		if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
		New-ItemProperty -Path $regPath -Name 'InstanceId' -Value $instanceId -PropertyType String -Force | Out-Null
	} catch {}
	$content = @(
		"InstanceId=$instanceId",
		"Computer=$($env:COMPUTERNAME)",
		"User=$($env:USERNAME)",
		"Created=$(Get-Date -Format o)"
	) -join [Environment]::NewLine
	$content | Set-Content -LiteralPath $marker -Encoding UTF8
}

function Test-SmartHealth {
	param([string]$SmartOptions, [string]$DevicePath, [switch]$Quiet)
	$smartctl = (Get-Command smartctl.exe -ErrorAction SilentlyContinue)
	if (-not $smartctl) {
		if (-not $Quiet) { Write-Warning 'smartctl not found. Skipping SMART check.' }
		return $true
	}
	try {
		if (-not $DevicePath) { throw 'SMART DevicePath not provided' }
		$smartArgs = @('-H','-d','auto', $DevicePath)
		if ($SmartOptions) { $smartArgs = $smartArgs + ($SmartOptions -split '\s+') }
		$psi = New-Object System.Diagnostics.ProcessStartInfo
		$psi.FileName = $smartctl.Source
		$psi.Arguments = [string]::Join(' ', $smartArgs)
		$psi.RedirectStandardOutput = $true
		$psi.UseShellExecute = $false
		$p = [System.Diagnostics.Process]::Start($psi)
		$out = $p.StandardOutput.ReadToEnd()
		$p.WaitForExit()
		$code = $p.ExitCode
		# smartctl exit code bitmask: 0 OK; any other bits indicate issues. Treat 0 as pass.
		if ($code -eq 0) { return $true }
		# Some devices may still return non-zero even when passing, try textual check as fallback
		if ($out -match '(?i)(overall[- ]?health).*?(PASSED|OK)') { return $true }
		if (-not $Quiet) {
			Write-Warning ("SMART check non-OK (code $code). Output: " + ($out | Select-String -Pattern '(?i)(health|fail|error)' -AllMatches | ForEach-Object { $_.Line } | Out-String))
		}
		return $false
	} catch {
		if (-not $Quiet) { Write-Warning "SMART check failed: $($_.Exception.Message)" }
		return $false
	}
}

function Get-BackupSources {
	param([hashtable]$Ini)
	$sources = @()
	if ($Ini.ContainsKey('Backup')) {
		foreach ($k in $Ini['Backup'].Keys) {
			# Skip filter keys
			if ($k -match '^(?i:(Include(File)?\d+|Exclude(File)?\d+|ExcludeDir\d+))$') { continue }
			$p = $Ini['Backup'][$k]
			if (-not [string]::IsNullOrWhiteSpace($p)) { $sources += $p }
		}
	}
	return $sources
}

function Get-BackupFilters {
	param([hashtable]$Ini)
	$filters = [ordered]@{
		IncludeFiles = @()
		ExcludeFiles = @()
		ExcludeDirs  = @()
	}
	if ($Ini.ContainsKey('Backup')) {
		foreach ($k in $Ini['Backup'].Keys) {
			$val = $Ini['Backup'][$k]
			if ($k -match '^(?i:Include(File)?\d+)$') { $filters.IncludeFiles += $val; continue }
			if ($k -match '^(?i:Exclude(File)?\d+)$') { $filters.ExcludeFiles += $val; continue }
			if ($k -match '^(?i:ExcludeDir\d+)$') { $filters.ExcludeDirs += $val; continue }
		}
	}
	return $filters
}

function Measure-FullDurationMinutes {
	param([string[]]$Sources)
	$totalBytes = 0
	foreach ($s in $Sources) {
		if (Test-Path -LiteralPath $s) {
			try {
				$totalBytes += (Get-ChildItem -LiteralPath $s -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Measure-Object Length -Sum).Sum
			} catch {}
		}
	}
	if (-not $totalBytes) { return 1 }
	$throughputBytesPerSec = 80MB # heuristic
	[int][Math]::Ceiling(($totalBytes / $throughputBytesPerSec) / 60)
}

function Show-FullBackupChoice {
	param([int]$EstimateMinutes, [int]$RemainingPostpones, [switch]$NoGui)
	$msg = "Je doporučena plná záloha. Odhad trvání: ${EstimateMinutes} min. Zbývající odklady: $RemainingPostpones.\n\nChcete spustit PLNOU zálohu nyní? [Y/N]"
	if (-not $NoGui) {
		try {
			Add-Type -AssemblyName PresentationFramework -ErrorAction Stop | Out-Null
			$title = 'Plná záloha doporučena'
			$buttons = [System.Windows.MessageBoxButton]::YesNo
			$icon = [System.Windows.MessageBoxImage]::Question
			$result = [System.Windows.MessageBox]::Show($msg, $title, $buttons, $icon)
			return $result -eq [System.Windows.MessageBoxResult]::Yes
		} catch {
			# fall through to console
		}
	}
	Write-Host $msg -ForegroundColor Yellow
	while ($true) {
		$ans = Read-Host 'Volba (Y/N)'
		if ($ans -match '^(?i:y|yes)$') { return $true }
		if ($ans -match '^(?i:n|no)$') { return $false }
	}
}

function Invoke-RobocopySet {
	param(
		[string[]]$Sources,
		[string]$DestRoot,
		[bool]$FullBackup,
		[string]$LogDir,
		[hashtable]$Filters,
		[switch]$WhatIf
	)
	if (!(Test-Path -LiteralPath $DestRoot)) { New-Item -ItemType Directory -Path $DestRoot -Force | Out-Null }
	if (!(Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
	$dateTag = Get-Date -Format 'yyyyMMdd-HHmmss'
	$exitCodes = @()
	foreach ($src in $Sources) {
		if (!(Test-Path -LiteralPath $src)) { Write-Warning "Source not found: $src"; continue }
		$leaf = Split-Path -Path $src -Leaf
		$dest = Join-Path -Path $DestRoot -ChildPath $leaf
		if (!(Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
		$logPath = Join-Path -Path $LogDir -ChildPath ("robocopy_${leaf}_${dateTag}.log")
		$common = @('/R:1','/W:3','/ZB','/FFT','/XJ','/MT:8','/NP',"/LOG+:$logPath")
		$flags = if ($FullBackup) { @('/MIR','/DCOPY:DAT','/COPY:DAT') } else { @('/E','/XO','/DCOPY:DAT','/COPY:DAT') }
		$includeFiles = @()
		$excludeFiles = @()
		$excludeDirs  = @()
		if ($Filters) {
			if ($Filters.IncludeFiles) { $includeFiles = $Filters.IncludeFiles }
			if ($Filters.ExcludeFiles) { $excludeFiles = $Filters.ExcludeFiles }
			if ($Filters.ExcludeDirs)  { $excludeDirs  = $Filters.ExcludeDirs }
		}
		# robocopy syntax: robocopy src dest [files...] [options]
		$rcArgs = @($src, $dest)
		if ($includeFiles.Count -gt 0) { $rcArgs += $includeFiles }
		$rcArgs += $flags + $common
		if ($excludeFiles.Count -gt 0) { $rcArgs += @('/XF') + $excludeFiles }
		if ($excludeDirs.Count -gt 0)  { $rcArgs += @('/XD') + $excludeDirs }
		Write-Host ("robocopy " + ($rcArgs -join ' ')) -ForegroundColor Cyan
		if ($WhatIf) { continue }
		$proc = Start-Process -FilePath robocopy.exe -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
		$exitCodes += $proc.ExitCode
	}
	return $exitCodes
}

function Get-RobocopyExitCodeSummary {
	param([int[]]$Codes)
	# 0/1 are OK; 2+ may indicate copies; 8+ errors
	$max = ($Codes | Measure-Object -Maximum).Maximum
	switch ($max) {
		{ $_ -lt 8 } { return 'SUCCESS (with copies and/or mismatches)'; }
		default { return "ERROR (max exit code $max)" }
	}
}

function Invoke-BackupMain {
try {
	$ini = Read-Ini -Path $ConfigPath
	$backupName = (Get-IniValue -Ini $ini -Section 'General' -Key 'BackupName' -Default 'Backup')
	$diskId = (Get-IniValue -Ini $ini -Section 'General' -Key 'DiskId' -Default '')
	$allowNoSmart = (Get-IniValue -Ini $ini -Section 'General' -Key 'AllowProceedNoSmart' -Default 'yes')
	$smartEvery = (Get-IniValue -Ini $ini -Section 'Smart' -Key 'SmartOnEveryRun' -Default 'no')
	$smartOpts = (Get-IniValue -Ini $ini -Section 'Smart' -Key 'SmartOptions' -Default '-H')
	$lastFull = (Get-IniValue -Ini $ini -Section 'General' -Key 'LastFullBackup' -Default '')
	$postpones = [int](Get-IniValue -Ini $ini -Section 'General' -Key 'FullBackupPostpones' -Default '0')

	$target = Get-TargetDriveInfo
	if (-not $diskId) {
		if ($target.UniqueId) {
			Write-Host "Storing DiskId=$($target.UniqueId) to INI" -ForegroundColor Yellow
			Set-IniValue -Path $ConfigPath -Section 'General' -Key 'DiskId' -Value $target.UniqueId
			$diskId = $target.UniqueId
		} else {
			Write-Warning 'Cannot determine UniqueId of target drive. Proceeding without storing DiskId.'
		}
	}

	# (SMART check moved below after target initialization)

		$sources = Get-BackupSources -Ini $ini
		$filters = Get-BackupFilters -Ini $ini
	if (-not $sources -or $sources.Count -eq 0) { throw 'No sources configured under [Backup] in INI.' }

	# If first-time run without target selection, run interactive initialization
	$targetDriveFromIni = (Get-IniValue -Ini $ini -Section 'General' -Key 'TargetDriveLetter' -Default '')
	$instanceFolder = (Get-IniValue -Ini $ini -Section 'General' -Key 'InstanceFolder' -Default '')
	if ([string]::IsNullOrWhiteSpace($targetDriveFromIni) -or [string]::IsNullOrWhiteSpace($instanceFolder)) {
		if ($Silent) { throw 'Nelze provést první inicializaci v tichém režimu. Spusťte skript interaktivně.' }
		$init = Initialize-BackupTarget -Ini $ini -ConfigPath $ConfigPath -BackupName $backupName -Sources $sources -NoGui:$NoGui
		if (-not $init.ProceedBackup) {
			Write-Host 'Inicializace dokončena, záloha nebyla spuštěna.' -ForegroundColor Yellow
			return 0
		}
		if ($init.FormatBefore) {
			Format-BackupVolume -DriveLetter $init.DriveLetter
		}
		# Refresh INI and target info after initialization
		$ini = Read-Ini -Path $ConfigPath
		$targetDriveFromIni = (Get-IniValue -Ini $ini -Section 'General' -Key 'TargetDriveLetter' -Default '')
		$instanceFolder = (Get-IniValue -Ini $ini -Section 'General' -Key 'InstanceFolder' -Default '')
		if ($targetDriveFromIni) { $target = Get-TargetDriveInfo -DriveLetter $targetDriveFromIni }
	}

	# Recompute target from INI if available and prepare dest root with instance folder
	$targetDriveFromIni = (Get-IniValue -Ini $ini -Section 'General' -Key 'TargetDriveLetter' -Default '')
	$instanceFolder = (Get-IniValue -Ini $ini -Section 'General' -Key 'InstanceFolder' -Default '')
	if ($targetDriveFromIni) { $target = Get-TargetDriveInfo -DriveLetter $targetDriveFromIni }
	$destRoot = Join-Path -Path ("$($target.DriveLetter):\") -ChildPath $backupName
	if ($instanceFolder) { $destRoot = Join-Path -Path $destRoot -ChildPath $instanceFolder }
	$logDir = Join-Path -Path $destRoot -ChildPath 'logs'

	# Now perform SMART check on the selected target disk if enabled
	if ($smartEvery -match '^(?i:yes|true|1)$') {
		$ok = Test-SmartHealth -SmartOptions $smartOpts -DevicePath $target.DevicePath -Quiet:($allowNoSmart -notmatch '^(?i:yes|true|1)$')
		if (-not $ok -and $allowNoSmart -notmatch '^(?i:yes|true|1)$') {
			throw 'SMART health check failed and AllowProceedNoSmart is disabled.'
		}
	}

	$isFirstRun = -not $lastFull
	$forceFull = [bool]$Full
	$dueFull = $false
	if (-not $isFirstRun -and -not $forceFull) {
		try {
			$dt = [datetime]::Parse($lastFull)
			$dueFull = ((Get-Date) -gt $dt.AddDays(90))
		} catch { $dueFull = $true }
	}

	$doFull = $false
		if ($Silent) {
			# Non-interactive policy: postpone up to 3x, pak plná
			if ($isFirstRun -or $forceFull) {
				$doFull = $true
			} elseif ($dueFull) {
				$remaining = [Math]::Max(0, 3 - $postpones)
				if ($remaining -le 0) { $doFull = $true }
				else { $postpones++; Set-IniValue -Path $ConfigPath -Section 'General' -Key 'FullBackupPostpones' -Value $postpones.ToString() }
			}
		} elseif ($isFirstRun -or $forceFull) {
		$doFull = $true
	} elseif ($dueFull) {
		$remaining = [Math]::Max(0, 3 - $postpones)
		if ($remaining -le 0) {
			$doFull = $true
		} else {
				$estimate = Measure-FullDurationMinutes -Sources $sources
				$yesNow = Show-FullBackupChoice -EstimateMinutes $estimate -RemainingPostpones $remaining -NoGui:$NoGui
			if ($yesNow) { $doFull = $true } else { $postpones++; Set-IniValue -Path $ConfigPath -Section 'General' -Key 'FullBackupPostpones' -Value $postpones.ToString() }
		}
	}

		# Ensure destination exists
		if (!(Test-Path -LiteralPath $destRoot)) { New-Item -ItemType Directory -Path $destRoot -Force | Out-Null }
	Write-InstanceMarker -DestRoot $destRoot -Ini $ini
		$codes = Invoke-RobocopySet -Sources $sources -DestRoot $destRoot -FullBackup:$doFull -LogDir $logDir -Filters $filters -WhatIf:$WhatIf
	$summary = Get-RobocopyExitCodeSummary -Codes $codes
	Write-Host "Robocopy summary: $summary" -ForegroundColor Green

	if (-not $WhatIf) {
		if ($doFull) {
			$today = (Get-Date).ToString('yyyy-MM-dd')
			Set-IniValue -Path $ConfigPath -Section 'General' -Key 'LastFullBackup' -Value $today
			Set-IniValue -Path $ConfigPath -Section 'General' -Key 'FullBackupPostpones' -Value '0'
		}
	}

		return 0
}
catch {
	Write-Error $_
		return 1
}
	}

	# Only run main when not dot-sourced (i.e., executed directly)
	if ($MyInvocation.InvocationName -ne '.') {
		$exit = Invoke-BackupMain
		exit $exit
	}

