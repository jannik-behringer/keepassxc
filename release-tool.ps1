<#
.SYNOPSIS
KeePassXC Release Tool

.DESCRIPTION
Commands:
  merge      Merge release branch into main branch and create release tags
  build      Build and package binary release from sources
  sign       Sign previously compiled release packages

.NOTES
The following are descriptions of certain parameters:
  -Vcpkg           Specify VCPKG toolchain file (example: C:\vcpkg\scripts\buildsystems\vcpkg.cmake)
  -Tag             Release tag to check out (defaults to version number)
  -Snapshot        Build current HEAD without checkout out Tag
  -CMakeGenerator  Override the default CMake generator
  -CMakeOptions    Additional CMake options for compiling the sources
  -CPackGenerators Set CPack generators (default: WIX;ZIP)
  -Compiler        Compiler to use (example: g++, clang, msbuild)
  -MakeOptions     Options to pass to the make program
  -SignBuild       Perform platform specific App Signing before packaging
  -SignKey         Specify the App Signing Key/Identity
  -TimeStamp       Explicitly set the timestamp server to use for appsign
  -SourceBranch    Source branch to merge from (default: 'release/$Version')
  -TargetBranch    Target branch to merge to (default: master)
  -VSToolChain     Specify Visual Studio Toolchain by name if more than one is available
#>

param(
    [Parameter(ParameterSetName = "merge", Mandatory, Position = 0)]
    [switch] $Merge,
    [Parameter(ParameterSetName = "build", Mandatory, Position = 0)]
    [switch] $Build,
    [Parameter(ParameterSetName = "sign", Mandatory, Position = 0)]
    [switch] $Sign,

    [Parameter(ParameterSetName = "merge", Mandatory, Position = 1)]
    [Parameter(ParameterSetName = "build", Mandatory, Position = 1)]
    [Parameter(ParameterSetName = "sign", Mandatory, Position = 1)]
    [ValidatePattern("^[0-9]\.[0-9]\.[0-9]$")]
    [string] $Version,

    [Parameter(ParameterSetName = "build", Mandatory)]
    [string] $Vcpkg,

    [Parameter(ParameterSetName = "sign", Mandatory)]
    [SupportsWildcards()]
    [string] $SignFiles,

    [Parameter(ParameterSetName = "build")]
    [switch] $DryRun,
    [Parameter(ParameterSetName = "build")]
    [switch] $Snapshot,
    [Parameter(ParameterSetName = "build")]
    [switch] $SignBuild,
    
    [Parameter(ParameterSetName = "build")]
    [string] $CMakeGenerator = "Ninja",
    [Parameter(ParameterSetName = "build")]
    [string] $CMakeOptions,
    [Parameter(ParameterSetName = "build")]
    [string] $CPackGenerators = "WIX;ZIP",
    [Parameter(ParameterSetName = "build")]
    [string] $Compiler,
    [Parameter(ParameterSetName = "build")]
    [string] $MakeOptions,
    [Parameter(ParameterSetName = "build")]
    [Parameter(ParameterSetName = "sign")]
    [string] $SignKey,
    [Parameter(ParameterSetName = "build")]
    [Parameter(ParameterSetName = "sign")]
    [string] $Timestamp = "http://timestamp.sectigo.com",
    [Parameter(ParameterSetName = "merge")]
    [Parameter(ParameterSetName = "build")]
    [Parameter(ParameterSetName = "sign")]
    [string] $GpgKey = "CFB4C2166397D0D2",
    [Parameter(ParameterSetName = "merge")]
    [Parameter(ParameterSetName = "build")]
    [string] $SourceDir = ".",
    [Parameter(ParameterSetName = "build")]
    [string] $OutDir = ".\release",
    [Parameter(ParameterSetName = "merge")]
    [Parameter(ParameterSetName = "build")]
    [string] $Tag,
    [Parameter(ParameterSetName = "merge")]
    [string] $SourceBranch,
    [Parameter(ParameterSetName = "merge")]
    [string] $TargetBranch = "master",
    [Parameter(ParameterSetName = "build")]
    [string] $VSToolChain
)

function Invoke-VSToolchain([String] $Toolchain, [String] $Path, [String] $Arch) {
    # Find Visual Studio installations
    $vs = Get-CimInstance MSFT_VSInstance
    if ($vs.count -eq 0) {
        $err = "No Visual Studio installations found, download one from https://visualstudio.com/downloads."
        $err = "$err`nIf Visual Studio is installed, you may need to repair the install then restart."
        throw $err
    }

    $VSBaseDir = $vs[0].InstallLocation
    if ($Toolchain) {
        # Try to find the specified toolchain by name
        foreach ($_ in $vs) {
            if ($_.Name -eq $Toolchain) {
                $VSBaseDir = $_.InstallLocation
                break
            }
        }
    }
    elseif ($vs.count -gt 1) {
        # Ask the user which install to use
        $i = 0
        foreach ($_ in $vs) {
            $i = $i + 1
            $i.ToString() + ") " + $_.Name | Write-Host
        }
        $i = Read-Host -Prompt "Which Visual Studio installation do you want to use?"
        $i = [Convert]::ToInt32($i, 10) - 1
        if ($i -lt 0 -or $i -ge $vs.count) {
            throw "Invalid selection made"
        }
        $VSBaseDir = $vs[$i].InstallLocation
    }
    
    # Bootstrap the specified VS Toolchain
    Import-Module "$VSBaseDir\Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
    Enter-VsDevShell -VsInstallPath $VSBaseDir -Arch $Arch -StartInPath $Path | Write-Host
    Write-Host # Newline after command output
}

function Invoke-Cmd([string] $command, [string[]] $options = @(), [switch] $maskargs) {
    $call = ('{0} {1}' -f $command, ($options -Join ' '))
    if ($maskargs) {
        Write-Host "$command <masked>" -ForegroundColor DarkGray
    }
    else {
        Write-Host $call -ForegroundColor DarkGray
    }
    Invoke-Expression $call
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to run command: {0}" -f $command
    }
    Write-Host #insert newline after command output
}

function Invoke-SignFiles([string[]] $files, [string] $key, [string] $time) {
    if (-not (Test-Path -Path "$key" -PathType leaf)) {
        throw "Appsign key file was not found! ($key)"
    }
    if ($files.Length -eq 0) {
        return
    }

    Write-Host "Signing executable files using $key"  -ForegroundColor Cyan
    $KeyPassword = Read-Host "Key password: " -MaskInput

    foreach ($_ in $files) {
        Write-Host "Signing file '$_' using Microsoft signtool..."
        Invoke-Cmd "signtool" "sign -f `"$key`" -p `"$KeyPassword`" -d `"KeePassXC`" -td sha256 -fd sha256 -tr `"$time`" `"$_`"" -maskargs
    }
}

# Handle errors and restore state
$CWD = $(Get-Location).Path
$OrigBranch = $(git rev-parse --abbrev-ref HEAD)
$ErrorActionPreference = 'Stop'
trap {
    # TODO: Only restore branch if changed
    Write-Host "Restoring state..." -ForegroundColor Yellow
    $(git checkout $OrigBranch)
    Set-Location -Path "$CWD"
}

Write-Host "KeePassXC Release Preparation Helper" -ForegroundColor Green
Write-Host "Copyright (C) 2021 KeePassXC Team <https://keepassxc.org/>`n" -ForegroundColor Green

# Resolve absolute directory for paths
$SourceDir = (Resolve-Path $SourceDir).Path
$OutDir = (Resolve-Path $OutDir).Path
$BuildDir = "$OutDir\build-release"
$Vcpkg = (Resolve-Path $Vcpkg).Path

if ($Merge) {

}
elseif ($Build) {
    # Find Visual Studio and establish build environment
    Invoke-VSToolchain $VSToolChain $SourceDir -Arch "amd64"

    if ($Snapshot) {
        $Tag = "HEAD"
        $SourceBranch = $(git rev-parse --abbrev-ref HEAD)
        $ReleaseName = "$Version-snapshot"
        $CMakeOptions = "$CMakeOptions -DKEEPASSXC_BUILD_TYPE=Snapshot -DOVERRIDE_VERSION=`"$ReleaseName`""
        Write-Host "Using current branch '$SourceBranch' to build."
    }
    else {
        # TODO: CheckWorkingTreeClean

        # Clear output directory
        if (Test-Path $OutDir) {
            Remove-Item $OutDir -Recurse
        }
        
        if ($Version -match "-beta\\d+$") {
            $CMakeOptions = "$CMakeOptions -DKEEPASSXC_BUILD_TYPE=PreRelease"
        }
        else {
            $CMakeOptions = "$CMakeOptions -DKEEPASSXC_BUILD_TYPE=Release"
        }

        # Setup Tag if not defined then checkout tag
        if ($Tag -eq "" -or $Tag -eq $null) {
            $Tag = $Version
        }
        Write-Host "Checking out tag 'tags/$Tag' to build."
        $(git checkout "tags/$Tag")
    }

    # Create directories
    New-Item -Path "$OutDir" -ItemType Directory -Force | Out-Null
    New-Item -Path "$BuildDir" -ItemType Directory -Force | Out-Null

    # Enter build directory
    Set-Location -Path "$BuildDir"

    # Setup CMake options
    $CMakeOptions = "$CMakeOptions -DWITH_XC_ALL=ON -DWITH_TESTS=OFF -DCMAKE_BUILD_TYPE=Release"
    $CMakeOptions = "$CMakeOptions -DCMAKE_TOOLCHAIN_FILE:FILEPATH=`"$Vcpkg`" -DX_VCPKG_APPLOCAL_DEPS_INSTALL=ON"

    Write-Host "Configuring build..." -ForegroundColor Cyan
    Invoke-Cmd "cmake" "$CMakeOptions -G `"$CMakeGenerator`" `"$SourceDir`""

    Write-Host "Compiling sources..." -ForegroundColor Cyan
    Invoke-Cmd "cmake" "--build . --config Release -- $MakeOptions"
    
    if ($SignBuild) {
        $files = Get-ChildItem -Path "$BuildDir\src" -Include "*.exe", "*.dll" -Recurse -Name `
        | Where-Object -FilterScript { $_ -match ".*keepassxc.*" } `
        | ForEach-Object { "$BuildDir\src\$_" }
        Invoke-SignFiles $files $SignKey $Timestamp
    }

    Write-Host "Create deployment packages..." -ForegroundColor Cyan
    Invoke-Cmd "cpack" "-G `"$CPackGenerators`""
    Move-Item "$BuildDir\keepassxc-*" -Destination "$OutDir" -Force

    # Enter output directory
    Set-Location -Path "$OutDir"

    if ($SignBuild) {
        # Sign MSI files using AppSign key
        $files = Get-ChildItem $OutDir -Include "*.msi" -Name | ForEach-Object { "$OutDir\$_" }
        Invoke-SignFiles $files $SignKey $Timestamp

        # Sign all output files using the GPG key then hash them
        $files = Get-ChildItem $OutDir -Include "*.msi", "*.zip" -Name
        foreach ($_ in $files) {
            Invoke-Cmd "gpg" "--output `"$_.sig`" --armor --local-user `"$GpgKey`" --detach-sig `"$_`""
            (Get-FileHash "$_" SHA256).Hash + " *$_" | Out-File "$_.DIGEST" -NoNewline
        }
    }

    # Restore state
    $(git checkout $OrigBranch)
    Set-Location -Path "$CWD"
}
elseif ($Sign) {

}



# cmake `
#   -G "Ninja" `
#   -DCMAKE_TOOLCHAIN_FILE="C:\vcpkg\scripts\buildsystems\vcpkg.cmake" `
#   -DCMAKE_CXX_FLAGS="-DQT_FORCE_ASSERTS" `
#   -DCMAKE_BUILD_TYPE="RelWithDebInfo" `
#   -DWITH_TESTS=ON `
#   -DWITH_GUI_TESTS=ON `
#   -DWITH_ASAN=OFF `
#   -DWITH_XC_ALL=ON `
#   -DWITH_XC_DOCS=ON `
#   -DCPACK_WIX_LIGHT_EXTRA_FLAGS='-sval' `
#   ..

# cmake --build . -- -j $env:NUMBER_OF_PROCESSORS

# cpack -G "ZIP;WIX"
