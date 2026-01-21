param (
        [parameter(Mandatory = $False)]
        [String] $prefix,
        [parameter(Mandatory = $False)]
        [String] $configdir,
        [parameter(Mandatory = $False)]
        [String] $destination,
        [parameter(Mandatory = $False)]
        [int] $timeout = 60,
        [parameter(Mandatory = $False)]
        [int] $concurrentBackups = 4,
        [parameter(Mandatory = $False)]
        [ValidateSet("rar", "7z")]
        [String] $compressor = "rar"
)

<#
    BackupFile saves all necessary information to create a backup file
#>
class BackupFile {
    [string] $backupsource
    [string] $backupdestination

    [string] $sourcedir
    [string] $filename
    [string] $options

    [int] $priority

    BackupFile() { }

    BackupFile(
        [string] $backupsource,
        [string] $backupdestination,

        [string] $sourcedir,
        [string] $filename,
        [string] $options,

        [int] $priority
    ) {
        $this.backupsource = $backupsource
        $this.backupdestination = $backupdestination

        $this.sourcedir = $sourcedir
        $this.filename = $filename
        $this.options = $options

        $this.priority = $priority
    }

    [string]ToString() {
        return ("BackupFile Source: {0}/{1} Destination: {2}/{3} Options: {4} Priority: {5}`n" -f
            $this.backupsource, $this.sourcedir, $this.backupdestination, $this.filename, $this.options, $this.priority)
    }
}

<#
    BackupStats continually updating statistics
#>
class BackupStats {
    [int] $totalJobs
    [int] $maxActiveJobs
    [int] $activeJobs = 0
    [int] $finishedJobs = 0
    [DateTime] $starttime

    BackupStats(
        [int] $totalJobs,
        [int] $maxActiveJobs
    ) {
        $this.totalJobs = $totalJobs
        $this.maxActiveJobs = $maxActiveJobs
        $this.starttime = Get-Date
    }

    StartJob() {
        $this.activeJobs += 1
    }

    FinishJob() {
        $this.activeJobs -= 1
        $this.finishedJobs += 1
    }

    [int] GetStartedJobs() {
        return ($this.finishedJobs + $this.currentJobs)
    }

    [int] GetActiveJobs() {
        return $this.activeJobs
    }

    [int] GetFinishedJobs() {
        return $this.finishedJobs
    }

    [int] GetTotalJobs() {
        return $this.totalJobs
    }

    [string]ToString() {
        $runtime = $(Get-Date) - $this.starttime

        return ("`n{0} Stats: Runtime: {1}`nJobs: {2} active {3} finished of {4} total`n" -f
            $(Get-Date), $runtime, $this.GetActiveJobs(), $this.GetFinishedJobs(), $this.GetTotalJobs())
    }

    [boolean]CanStartJob() {

        if($this.GetActiveJobs() -lt $this.maxActiveJobs) {
            return $true
        }

        return $false
    }
}

<#
    Commandlet to initialize BackupConfig
#>
function Start-Backup {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $True)]
        [String] $configdir,
        [parameter(Mandatory = $True)]
        [String] $prefix,
        [parameter(Mandatory = $False)]
        [String] $destination,
        [parameter(Mandatory = $False)]
        [int] $timeout = 30,
        [parameter(Mandatory = $False)]
        [int] $concurrentBackups = 4,
        [parameter(Mandatory = $False)]
        [ValidateSet("rar", "7z")]
        [String] $compressor = "rar"
    )

    $compressors = @{
        "rar" = @{
            extension = ".rar"
            command = "rar"
            args = "a {0} `"{1}`" `"{2}`""
            install = @{
                Windows = "winget install win.rar.WinRAR"
                macOS   = "brew install rar"
                Linux   = "sudo apt-get install rar  # Debian/Ubuntu`n                         sudo dnf install rar     # Fedora/RHEL"
            }
        }
        "7z" = @{
            extension = ".7z"
            command = "7z"
            args = "a {0} `"{1}`" `"{2}`""
            install = @{
                Windows = "winget install 7zip.7zip"
                macOS   = "brew install 7zip"
                Linux   = "sudo apt-get install 7zip  # Debian/Ubuntu`n                         sudo dnf install 7zip     # Fedora/RHEL"
            }
        }
    }
    $comp = $compressors[$compressor]

    if (!(Get-Command $comp.command -ErrorAction SilentlyContinue)) {
        $os = if ($IsWindows) { "Windows" } elseif ($IsMacOS) { "macOS" } else { "Linux" }
        Write-Host -ForegroundColor Red "Error: '$($comp.command)' is not installed or not found in PATH."
        Write-Host ""
        Write-Host "To install $compressor on $os, run:"
        Write-Host -ForegroundColor Cyan "  $($comp.install[$os])"
        Write-Host ""
        return
    }

    $backupfiles = @()

    $list = Get-ChildItem -Path $configdir -Filter "*.json"

    foreach($file in $list) {
        $config = (Get-Content $file -Raw) | ConvertFrom-Json
        $source = $config.Source

        if(!$destination) {
            $destination = $config.Destination
        }

        if (!(Test-Path -Path $source)) {
            Write-Host -ForegroundColor Yellow -BackgroundColor Black $("{0,32}: {1} {2}" -f "Backup Source", $source, "NOT FOUND")
            continue
        }

        if (!(Test-Path -Path $destination)) {
            Write-Host -ForegroundColor Yellow -BackgroundColor Black $("{0,32}: {1} {2}" -f "Backup Destination", $destination, "NOT FOUND")
            continue
        }

        foreach($backup in $config.backups) {
            $priority = 999

            if($backup.Priority) {
                $priority = $backup.Priority
            }

            $filename = "$prefix-$($backup.Name)$($comp.extension)"

            $backupfiles += [BackupFile]::new($source, $destination, $backup.Source, $filename, $backup.Options, $priority)
        }
    }

    $stats = [BackupStats]::new($backupfiles.Count, $concurrentBackups)

    $backupfiles = $backupfiles | Sort-Object -Property priority

    $procs = @()
    foreach($backupfile in $backupfiles) {
        $procs += Start-Process -FilePath $comp.command -ArgumentList ($comp.args -f $backupfile.options, "$($backupfile.backupdestination)/$($backupfile.filename)", "$($backupfile.backupsource)/$($backupfile.sourcedir)") -PassThru
        $stats.StartJob()

        $stats.ToString()

        while(!$stats.CanStartJob()) {
            Start-Sleep $timeout
            $stats.ToString()

            $finished, $procs = $procs.Where({$_.HasExited}, 'Split')
            foreach($proc in $finished) {
                $stats.FinishJob()
            }
        }
    }

    foreach($proc in $procs) {
        $proc.WaitForExit()
        $stats.FinishJob()
        $stats.ToString()
    }

}

if(Test-Path -Path "$PSScriptRoot/hooks/pre-backup.ps1") {
    & pwsh "$PSScriptRoot/hooks/pre-backup.ps1"
}

if(!$prefix) {
    $prefix = Get-Date -Format "yyyy-MM"
}

if(!$configdir) {
    $configdir = "config"
}

if($destination) {
    Start-Backup -configdir $configdir -prefix $prefix -timeout $timeout -destination $destination -concurrentBackups $concurrentBackups -compressor $compressor
} else {
    Start-Backup -configdir $configdir -prefix $prefix -timeout $timeout -concurrentBackups $concurrentBackups -compressor $compressor
}

if(Test-Path -Path "$PSScriptRoot/hooks/post-backup.ps1") {
    & pwsh "$PSScriptRoot/hooks/post-backup.ps1"
}
