param(
    [string]$TargetDir = "C:\doks asli",
    [double]$MinSizeMB = 50,
    [int]$JpegQuality = 75,
    [int]$MaxImageDim = 1600,
    [string]$BackupDir = "",
    [string]$GsDllPath = ""
)

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.Drawing

$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
    Where-Object { $_.MimeType -eq 'image/jpeg' } |
    Select-Object -First 1

function Resize-And-RecompressImage {
    param(
        [string]$ImagePath,
        [int]$Quality,
        [int]$MaxDim
    )
    $ext = [System.IO.Path]::GetExtension($ImagePath).ToLowerInvariant()
    if ($ext -notin @('.jpg', '.jpeg', '.png')) { return }

    $bytes = [System.IO.File]::ReadAllBytes($ImagePath)
    $ms = New-Object System.IO.MemoryStream(,$bytes)
    $img = $null
    $bmp = $null
    $g = $null

    try {
        $img = [System.Drawing.Image]::FromStream($ms)
        $w = $img.Width
        $h = $img.Height

        $scale = 1.0
        if ([Math]::Max($w, $h) -gt $MaxDim) {
            $scale = $MaxDim / [double][Math]::Max($w, $h)
        }

        $newW = [Math]::Max(1, [int][Math]::Round($w * $scale))
        $newH = [Math]::Max(1, [int][Math]::Round($h * $scale))

        # Untuk PNG hanya proses jika perlu resize agar referensi XML .docx tetap valid
        if ($ext -eq '.png' -and $scale -eq 1.0) { return }

        $bmp = New-Object System.Drawing.Bitmap($newW, $newH)
        $bmp.SetResolution($img.HorizontalResolution, $img.VerticalResolution)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $g.DrawImage($img, 0, 0, $newW, $newH)

        $tmpImg = "$ImagePath.tmp"
        if ($ext -eq '.png') {
            $bmp.Save($tmpImg, [System.Drawing.Imaging.ImageFormat]::Png)
        } else {
            $encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
            $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                [System.Drawing.Imaging.Encoder]::Quality, [long]$Quality
            )
            $bmp.Save($tmpImg, $jpegCodec, $encParams)
            $encParams.Dispose()
        }

        if ((Get-Item $tmpImg).Length -lt $bytes.Length) {
            Move-Item -LiteralPath $tmpImg -Destination $ImagePath -Force
        } else {
            Remove-Item -LiteralPath $tmpImg -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        if ($g) { $g.Dispose() }
        if ($bmp) { $bmp.Dispose() }
        if ($img) { $img.Dispose() }
        if ($ms) { $ms.Dispose() }
    }
}

function Compress-DocxInPlace {
    param([System.IO.FileInfo]$File)

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("docx_" + [guid]::NewGuid().ToString("N"))
    $tempZip = Join-Path ([System.IO.Path]::GetTempPath()) ("docx_" + [guid]::NewGuid().ToString("N") + ".docx")

    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($File.FullName, $tempDir)

        $mediaDir = Join-Path $tempDir "word\media"
        if (Test-Path $mediaDir) {
            Get-ChildItem -Path $mediaDir -File | ForEach-Object {
                Resize-And-RecompressImage -ImagePath $_.FullName -Quality $JpegQuality -MaxDim $MaxImageDim
            }
        }

        # Re-zip dengan separator '/' agar valid untuk Microsoft Word
        $zip = [System.IO.Compression.ZipFile]::Open($tempZip, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $baseLen = $tempDir.TrimEnd('\').Length + 1
            Get-ChildItem -Path $tempDir -Recurse -File | ForEach-Object {
                $relPath = $_.FullName.Substring($baseLen) -replace '\\', '/'
                [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $zip, $_.FullName, $relPath, [System.IO.Compression.CompressionLevel]::Optimal
                ) | Out-Null
            }
        }
        finally {
            $zip.Dispose()
        }

        $newSize = (Get-Item $tempZip).Length
        if ($newSize -lt $File.Length) {
            Move-Item -LiteralPath $tempZip -Destination $File.FullName -Force
            return $newSize
        }
        return $File.Length
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
    }
}

function Find-Ghostscript {
    foreach ($cmd in @("gswin64c", "gswin32c", "gs")) {
        $found = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($found) { return $found.Source }
    }
    $pf = Get-ChildItem "C:\Program Files\gs\*\bin\gswin64c.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pf) { return $pf.FullName }
    return $null
}

function Find-GhostscriptDll {
    param([string]$HintPath)
    if ($HintPath -and (Test-Path $HintPath)) { return $HintPath }
    $pf = Get-ChildItem "C:\Program Files\gs\*\bin\gsdll64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pf) { return $pf.FullName }
    $local = "C:\Users\ADVAN\.gemini\antigravity\brain\9aac133e-8b61-4f52-9a95-e0a93af08b80\scratch\gs_pkg\extracted\runtimes\win-x64\native\gsdll64.dll"
    if (Test-Path $local) { return $local }
    return $null
}

function Initialize-GsNative {
    param([string]$DllPath)
    if (-not ([System.Management.Automation.PSTypeName]'GsNativeRunner').Type) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class GsNativeRunner {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadLibrary(string lpFileName);

    [DllImport("gsdll64.dll")]
    private static extern int gsapi_new_instance(out IntPtr pinstance, IntPtr caller_handle);

    [DllImport("gsdll64.dll")]
    private static extern int gsapi_set_arg_encoding(IntPtr instance, int encoding);

    [DllImport("gsdll64.dll")]
    private static extern int gsapi_init_with_args(IntPtr instance, int argc, IntPtr[] argv);

    [DllImport("gsdll64.dll")]
    private static extern int gsapi_exit(IntPtr instance);

    [DllImport("gsdll64.dll")]
    private static extern void gsapi_delete_instance(IntPtr instance);

    private static bool _loaded = false;

    public static void EnsureLoaded(string dllPath) {
        if (_loaded) return;
        IntPtr h = LoadLibrary(dllPath);
        if (h == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        _loaded = true;
    }

    public static int Run(string[] args) {
        IntPtr inst;
        int rc = gsapi_new_instance(out inst, IntPtr.Zero);
        if (rc < 0) return rc;
        IntPtr[] ptrs = new IntPtr[args.Length];
        try {
            gsapi_set_arg_encoding(inst, 1);
            for (int i = 0; i < args.Length; i++) {
                byte[] b = Encoding.UTF8.GetBytes(args[i] + "\0");
                ptrs[i] = Marshal.AllocHGlobal(b.Length);
                Marshal.Copy(b, 0, ptrs[i], b.Length);
            }
            rc = gsapi_init_with_args(inst, args.Length, ptrs);
            int rc2 = gsapi_exit(inst);
            return (rc < 0) ? rc : rc2;
        } finally {
            for (int i = 0; i < ptrs.Length; i++) {
                if (ptrs[i] != IntPtr.Zero) Marshal.FreeHGlobal(ptrs[i]);
            }
            gsapi_delete_instance(inst);
        }
    }
}
"@
    }
    [GsNativeRunner]::EnsureLoaded($DllPath)
}

function Compress-PdfInPlace {
    param(
        [System.IO.FileInfo]$File,
        [string]$GsExe,
        [string]$GsDll,
        [double]$TargetMB
    )

    $bestTemp = $null
    $bestSize = $File.Length

    try {
        foreach ($preset in @("/printer", "/ebook", "/screen")) {
            $tempPdf = Join-Path ([System.IO.Path]::GetTempPath()) ("pdf_" + [guid]::NewGuid().ToString("N") + ".pdf")
            $gsArgs = @(
                "-sDEVICE=pdfwrite",
                "-dCompatibilityLevel=1.4",
                "-dPDFSETTINGS=$preset",
                "-dNOPAUSE",
                "-dQUIET",
                "-dBATCH",
                "-sOutputFile=$tempPdf",
                $File.FullName
            )

            $ok = $false
            if ($GsExe) {
                & $GsExe @gsArgs
                $ok = ($LASTEXITCODE -eq 0)
            } elseif ($GsDll) {
                $rc = [GsNativeRunner]::Run(@("gs") + $gsArgs)
                $ok = ($rc -ge 0)
            }

            if ($ok -and (Test-Path $tempPdf)) {
                $newSize = (Get-Item $tempPdf).Length
                if ($newSize -lt $bestSize) {
                    if ($bestTemp -and (Test-Path $bestTemp)) {
                        Remove-Item -LiteralPath $bestTemp -Force -ErrorAction SilentlyContinue
                    }
                    $bestTemp = $tempPdf
                    $bestSize = $newSize
                } else {
                    Remove-Item -LiteralPath $tempPdf -Force -ErrorAction SilentlyContinue
                }

                if (($bestSize / 1MB) -lt $TargetMB) {
                    break
                }
            } else {
                Remove-Item -LiteralPath $tempPdf -Force -ErrorAction SilentlyContinue
            }
        }

        if ($bestTemp -and $bestSize -lt $File.Length) {
            Move-Item -LiteralPath $bestTemp -Destination $File.FullName -Force
            return $bestSize
        }
        return $File.Length
    }
    finally {
        if ($bestTemp -and (Test-Path $bestTemp)) {
            Remove-Item -LiteralPath $bestTemp -Force -ErrorAction SilentlyContinue
        }
    }
}

$gsExe = Find-Ghostscript
$gsDll = $null
if (-not $gsExe) {
    $gsDll = Find-GhostscriptDll -HintPath $GsDllPath
    if ($gsDll) {
        Initialize-GsNative -DllPath $gsDll
    }
}

$minBytes = [long]($MinSizeMB * 1MB)
$targets = Get-ChildItem -Path $TargetDir -Recurse -File | Where-Object {
    $_.Length -gt $minBytes -and $_.Extension.ToLowerInvariant() -in @('.pdf', '.docx')
}

if (-not $targets) {
    Write-Host "Tidak ada file .pdf / .docx > $MinSizeMB MB." -ForegroundColor Green
    exit 0
}

if ($BackupDir) {
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
}

foreach ($f in $targets) {
    $beforeMB = [math]::Round($f.Length / 1MB, 2)
    $ext = $f.Extension.ToLowerInvariant()

    if ($BackupDir) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $BackupDir $f.Name) -Force
    }

    if ($ext -eq '.docx') {
        $afterBytes = Compress-DocxInPlace -File $f
        $afterMB = [math]::Round($afterBytes / 1MB, 2)
        Write-Host "[DOCX] $($f.Name): $beforeMB MB -> $afterMB MB"
    }
    elseif ($ext -eq '.pdf') {
        if (-not $gsExe -and -not $gsDll) {
            Write-Warning "[PDF] Lewati $($f.Name) ($beforeMB MB): Ghostscript belum terpasang."
            continue
        }
        $afterBytes = Compress-PdfInPlace -File $f -GsExe $gsExe -GsDll $gsDll -TargetMB $MinSizeMB
        $afterMB = [math]::Round($afterBytes / 1MB, 2)
        Write-Host "[PDF]  $($f.Name): $beforeMB MB -> $afterMB MB"
    }
}

