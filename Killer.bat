@echo off
setlocal
title ProcKiller
powershell -NoProfile -ExecutionPolicy Bypass -Command "$Self='%~f0'; $Mode='%~1'; $parts=(Get-Content -LiteralPath $Self -Raw) -split 'PSBODY_MARKER_LINE'; Invoke-Expression $parts[-1]"
echo.
echo [script ended] Press any key to close this window.
pause >nul
exit /b

PSBODY_MARKER_LINE
# ===================== PowerShell body =====================
$ErrorActionPreference = 'Continue'

$Pattern         = 'AppGuard'    # matched against name / title / description / product
$IntervalSeconds = 0.5
$Dir             = Split-Path -Parent $Self
$LogFile         = Join-Path $Dir 'kill_log.txt'

# never touch ourselves or the shell that hosts us
$SelfPid   = $PID
$SkipNames = @('cmd','powershell','pwsh','conhost','WindowsTerminal','OpenConsole','explorer')

function Log($msg){
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $msg
    Write-Host $line
    try { $line | Out-File -FilePath $LogFile -Append -Encoding UTF8 } catch { }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Log "=== Proc Killer start ==="
Log ("Script  : " + $Self)
Log ("Log file: " + $LogFile)
Log ("Pattern : " + $Pattern)
Log ("Admin   : " + $isAdmin + "   MyPID=" + $SelfPid)

if( -not $isAdmin -and $Mode -ne 'elevated' ){
    Log 'Not admin. Requesting elevation...'
    try{
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', ('"' + $Self + '" elevated') -Verb RunAs -ErrorAction Stop
        Log 'Elevated window launched. This one exits.'
        return
    }catch{
        Log ('Elevation declined/failed: ' + $_.Exception.Message + '  -> continuing without admin.')
    }
}

# ---------- full diagnostic dump (once) ----------
$procDump = Join-Path $Dir 'all_processes.txt'
$svcDump  = Join-Path $Dir 'all_services.txt'
Log ('Writing full process list -> ' + $procDump)
Get-Process | Sort-Object ProcessName |
    Select-Object Id, ProcessName, SessionId, MainWindowTitle, Description, Product, Company, Path |
    Format-Table -AutoSize | Out-String -Width 500 |
    Out-File -FilePath $procDump -Encoding UTF8
Log ('Writing full service list -> ' + $svcDump)
Get-CimInstance Win32_Service | Sort-Object DisplayName |
    Select-Object Name, DisplayName, State, StartMode, ProcessId, PathName |
    Format-Table -AutoSize | Out-String -Width 500 |
    Out-File -FilePath $svcDump -Encoding UTF8

Log '--- current AppGuard-like matches ---'
$any=$false
Get-Process | Where-Object {
    ("$($_.ProcessName) $($_.MainWindowTitle) $($_.Description) $($_.Product)" -like "*$Pattern*")
} | ForEach-Object {
    $any=$true
    Log ("MATCH PID={0} Name='{1}' Desc='{2}' Path='{3}'" -f $_.Id,$_.ProcessName,$_.Description,$_.Path)
}
if(-not $any){ Log ("No process currently matches '*$Pattern*'. See all_processes.txt / all_services.txt to find the real name.") }
Log '--- watching (Ctrl+C to stop) ---'

$tick=0
while($true){
    $procs = Get-Process | Where-Object {
        $_.Id -ne $SelfPid -and
        ($SkipNames -notcontains $_.ProcessName) -and
        (
            $_.ProcessName     -like "*$Pattern*" -or
            $_.MainWindowTitle -like "*$Pattern*" -or
            ($_.Description -and $_.Description -like "*$Pattern*") -or
            ($_.Product     -and $_.Product     -like "*$Pattern*")
        )
    }
    foreach($p in $procs){
        $info = "PID={0} Name='{1}' Title='{2}' Desc='{3}'" -f $p.Id,$p.ProcessName,$p.MainWindowTitle,$p.Description
        try{
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Log ("KILLED  " + $info)
        }catch{
            Log ("FAILED  " + $info + "  Error: " + $_.Exception.Message)
        }
    }
    $tick++
    if($tick % 20 -eq 0){ Log 'watching...' }
    Start-Sleep -Milliseconds ([int]($IntervalSeconds*1000))
}
