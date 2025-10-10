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
	# Determine target drive from script location drive letter
	$driveLetter = (Split-Path -Qualifier -Path $PSScriptRoot).TrimEnd(':', '\')
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

		if ($smartEvery -match '^(?i:yes|true|1)$') {
			$ok = Test-SmartHealth -SmartOptions $smartOpts -DevicePath $target.DevicePath -Quiet:($allowNoSmart -notmatch '^(?i:yes|true|1)$')
		if (-not $ok -and $allowNoSmart -notmatch '^(?i:yes|true|1)$') {
			throw 'SMART health check failed and AllowProceedNoSmart is disabled.'
		}
	}

		$sources = Get-BackupSources -Ini $ini
		$filters = Get-BackupFilters -Ini $ini
	if (-not $sources -or $sources.Count -eq 0) { throw 'No sources configured under [Backup] in INI.' }

	$destRoot = Join-Path -Path ("$($target.DriveLetter):\") -ChildPath $backupName
	$logDir = Join-Path -Path $destRoot -ChildPath 'logs'

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

