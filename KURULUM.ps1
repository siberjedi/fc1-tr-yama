param([string]$OyunKlasoru)

[Console]::OutputEncoding = [Text.UTF8Encoding]::new()

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

if ([string]::IsNullOrWhiteSpace($OyunKlasoru)) {
    $kayitYollari = @(
        'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs\84',
        'HKLM:\SOFTWARE\Ubisoft\Launcher\Installs\84'
    )
    foreach ($kayitYolu in $kayitYollari) {
        $kayit = Get-ItemProperty -Path $kayitYolu -ErrorAction SilentlyContinue
        if ($null -ne $kayit -and -not [string]::IsNullOrWhiteSpace($kayit.InstallDir)) {
            $OyunKlasoru = [string]$kayit.InstallDir
            break
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($OyunKlasoru)) {
    $OyunKlasoru = $OyunKlasoru.Trim().Trim([char]'"')
}

if ([string]::IsNullOrWhiteSpace($OyunKlasoru) -or -not (Test-Path -LiteralPath $OyunKlasoru -PathType Container)) {
    Write-Host "HATA: Oyun klasörü bulunamadı. Kurulum için -OyunKlasoru parametresini kullanın." -ForegroundColor Red
    exit 1
}

function Apply-Edits {
    param([string]$Metin, $Duzenlemeler)

    if ($null -eq $Duzenlemeler -or $Duzenlemeler.Count -eq 0) {
        return $Metin
    }

    $sirali = @($Duzenlemeler | Sort-Object Start -Descending)
    $parcalar = [System.Collections.Generic.List[string]]::new()
    $son = $Metin.Length

    foreach ($d in $sirali) {
        $baslangic = [int]$d.Start
        $uzunluk = [int]$d.Length
        $bitis = $baslangic + $uzunluk
        if ($bitis -gt $son) { continue }
        $parcalar.Add($Metin.Substring($bitis, $son - $bitis))
        $parcalar.Add([string]$d.New)
        $son = $baslangic
    }

    $parcalar.Add($Metin.Substring(0, $son))

    $sonuc = [System.Text.StringBuilder]::new()
    for ($i = $parcalar.Count - 1; $i -ge 0; $i--) {
        [void]$sonuc.Append($parcalar[$i])
    }

    return $sonuc.ToString()
}

function Escape-XmlMetin {
    param([string]$Metin)
    return $Metin.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Convert-XmlMetin {
    param([string]$Xml, [hashtable]$Sozluk)

    $rowRegex = [regex]'(?s)(<Row\b[^>]*>)(.*?)(</Row>)'
    $dataRegex = [regex]'(?s)(<Data\b[^>]*>)(.*?)(</Data>)'

    $duzenlemeler = [System.Collections.Generic.List[object]]::new()
    $degisen = 0

    foreach ($row in $rowRegex.Matches($Xml)) {
        $icerik = $row.Groups[2]
        $dataEslesmeleri = $dataRegex.Matches($icerik.Value)
        if ($dataEslesmeleri.Count -lt 2) { continue }

        $ikinci = $dataEslesmeleri[1]
        $hamIkinci = $ikinci.Groups[2].Value
        $cozulmus = [System.Net.WebUtility]::HtmlDecode($hamIkinci).Trim()

        if ([string]::IsNullOrEmpty($cozulmus)) { continue }
        if ($cozulmus -eq 'English') { continue }

        $bulundu = $false
        $ceviri = $null

        if ($Sozluk.ContainsKey($cozulmus)) {
            $ceviri = $Sozluk[$cozulmus]
            $bulundu = $true
        }
        elseif ($Sozluk.ContainsKey($hamIkinci)) {
            $ceviri = $Sozluk[$hamIkinci]
            $bulundu = $true
        }

        if (-not $bulundu) { continue }

        $yeniDeger = Escape-XmlMetin -Metin ([string]$ceviri)
        $icDuzenlemeler = [System.Collections.Generic.List[object]]::new()
        $satirDegisen = 0

        for ($k = 1; $k -lt $dataEslesmeleri.Count -and $k -le 2; $k++) {
            $veri = $dataEslesmeleri[$k]
            $eskiIcerik = $veri.Groups[2].Value
            if ($eskiIcerik -eq $yeniDeger) { continue }
            $icDuzenlemeler.Add([pscustomobject]@{
                Start = $veri.Groups[2].Index
                Length = $eskiIcerik.Length
                New = $yeniDeger
            })
            $satirDegisen = $satirDegisen + 1
        }

        if ($icDuzenlemeler.Count -eq 0) { continue }

        $yeniIcerik = Apply-Edits -Metin $icerik.Value -Duzenlemeler $icDuzenlemeler
        $duzenlemeler.Add([pscustomobject]@{
            Start = $icerik.Index
            Length = $icerik.Length
            New = $yeniIcerik
        })
        $degisen = $degisen + $satirDegisen
    }

    if ($duzenlemeler.Count -eq 0) {
        return [pscustomobject]@{ Metin = $Xml; Degisen = 0 }
    }

    $yeniXml = Apply-Edits -Metin $Xml -Duzenlemeler $duzenlemeler
    return [pscustomobject]@{ Metin = $yeniXml; Degisen = $degisen }
}

function Convert-Pak {
    param(
        [string]$Kaynak,
        [string]$Hedef,
        [hashtable]$Sozluk,
        [ref]$Degisen,
        [ref]$Bozuk
    )

    $gecici = $Hedef + '.tmp'

    if (Test-Path -LiteralPath $gecici) {
        Remove-Item -LiteralPath $gecici -Force
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $kaynakZip = $null
    $hedefZip = $null
    $hedefAkis = $null
    $degisenSayisi = 0
    $tasindi = $false

    try {
        $kaynakZip = [System.IO.Compression.ZipFile]::OpenRead($Kaynak)
        $hedefAkis = [System.IO.File]::Open($gecici, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $hedefZip = [System.IO.Compression.ZipArchive]::new($hedefAkis, [System.IO.Compression.ZipArchiveMode]::Create)

        foreach ($giris in $kaynakZip.Entries) {
            $girisAkis = $null
            $bellek = $null
            $okundu = $false

            try {
                $girisAkis = $giris.Open()
                $bellek = [System.IO.MemoryStream]::new()
                $girisAkis.CopyTo($bellek)
                $okundu = $true
            }
            catch {
                Write-Host ("UYARI: '" + $giris.FullName + "' okunamadı, atlandı. (" + $_.Exception.Message + ")") -ForegroundColor Yellow
                $Bozuk.Value = [int]$Bozuk.Value + 1
            }
            finally {
                if ($null -ne $girisAkis) { $girisAkis.Dispose() }
            }

            if (-not $okundu) {
                if ($null -ne $bellek) { $bellek.Dispose() }
                continue
            }

            [byte[]]$baytlar = $bellek.ToArray()
            $bellek.Dispose()
            $bellek = $null

            if ($giris.FullName -match '(?i)\.xml$') {
                $eskiMetin = $utf8.GetString($baytlar)
                $xmlSonuc = Convert-XmlMetin -Xml $eskiMetin -Sozluk $Sozluk
                $degisenSayisi = $degisenSayisi + [int]$xmlSonuc.Degisen
                $baytlar = $utf8.GetBytes([string]$xmlSonuc.Metin)
            }

            $cikisAkis = $null

            try {
                $yeniGiris = $hedefZip.CreateEntry($giris.FullName)
                $cikisAkis = $yeniGiris.Open()
                $cikisAkis.Write($baytlar, 0, $baytlar.Length)
            }
            catch {
                Write-Host ("UYARI: '" + $giris.FullName + "' yazılamadı, atlandı. (" + $_.Exception.Message + ")") -ForegroundColor Yellow
                $Bozuk.Value = [int]$Bozuk.Value + 1
            }
            finally {
                if ($null -ne $cikisAkis) { $cikisAkis.Dispose() }
            }
        }

        $hedefZip.Dispose()
        $hedefZip = $null
        $hedefAkis.Dispose()
        $hedefAkis = $null
        $kaynakZip.Dispose()
        $kaynakZip = $null

        Move-Item -LiteralPath $gecici -Destination $Hedef -Force
        $tasindi = $true
        $Degisen.Value = [int]$Degisen.Value + $degisenSayisi
        return $true
    }
    catch {
        Write-Host ("UYARI: '" + (Split-Path -Leaf $Hedef) + "' işlenemedi. (" + $_.Exception.Message + ")") -ForegroundColor Yellow
        return $false
    }
    finally {
        if ($null -ne $hedefZip) { $hedefZip.Dispose() }
        if ($null -ne $hedefAkis) { $hedefAkis.Dispose() }
        if ($null -ne $kaynakZip) { $kaynakZip.Dispose() }
        if (-not $tasindi -and (Test-Path -LiteralPath $gecici)) {
            Remove-Item -LiteralPath $gecici -Force -ErrorAction SilentlyContinue
        }
    }
}

$betikKlasoru = Split-Path -Parent $MyInvocation.MyCommand.Path
$ceviriYolu = Join-Path $betikKlasoru 'ceviriler.tsv'

if (-not (Test-Path -LiteralPath $ceviriYolu)) {
    Write-Host ("HATA: Çeviri dosyası bulunamadı: " + $ceviriYolu) -ForegroundColor Red
    exit 1
}

$ceviriMetni = [System.IO.File]::ReadAllText($ceviriYolu, [System.Text.Encoding]::UTF8)
$sozluk = [System.Collections.Hashtable]::new([System.StringComparer]::Ordinal)
$satirlar = $ceviriMetni -split "\r?\n"

for ($i = 1; $i -lt $satirlar.Count; $i++) {
    $satir = $satirlar[$i]
    if ([string]::IsNullOrEmpty($satir)) { continue }

    $parcalar = $satir.Split([char]9)
    if ($parcalar.Count -ne 4) { continue }

    $anahtar = $parcalar[2]
    if ([string]::IsNullOrEmpty($anahtar)) { continue }

    $deger = $parcalar[3]
    $sozluk[$anahtar] = $deger

    $kisaAnahtar = $anahtar.Trim()
    if ($kisaAnahtar.Length -gt 0 -and -not $sozluk.ContainsKey($kisaAnahtar)) {
        $sozluk[$kisaAnahtar] = $deger
    }
}

$localized = Join-Path $OyunKlasoru 'FCData\Localized'
$hedefler = [System.Collections.Generic.List[object]]::new()

$pakBir = Join-Path $localized 'english1.pak'
$hedefler.Add([pscustomobject]@{ Kaynak = $pakBir; Hedef = $pakBir })

$pakIki = Join-Path $localized 'english2.pak'
$hedefler.Add([pscustomobject]@{ Kaynak = $pakIki; Hedef = $pakIki })

$pakAna = Join-Path $localized 'english.pak'
$pakDestek = Join-Path $OyunKlasoru 'Support\inst\data\EN\english.pak'

if (Test-Path -LiteralPath $pakAna) {
    $pakAnaKaynak = $pakAna
}
elseif (Test-Path -LiteralPath $pakDestek) {
    $pakAnaKaynak = $pakDestek
}
else {
    $pakAnaKaynak = $null
}

if ($null -ne $pakAnaKaynak) {
    $hedefler.Add([pscustomobject]@{ Kaynak = $pakAnaKaynak; Hedef = $pakAna })
}
else {
    Write-Host "UYARI: english.pak kaynağı bulunamadı, bu dosya atlanıyor." -ForegroundColor Yellow
}

$zaman = Get-Date -Format 'yyyyMMdd_HHmmss'
$yedekKlasoru = Join-Path $localized ("_TR_Yama_Yedek_" + $zaman)
$yedeklenen = @{}
$yedekVar = $false

foreach ($hedef in $hedefler) {
    if (-not (Test-Path -LiteralPath $hedef.Hedef)) { continue }

    $anahtar = $hedef.Hedef.ToLowerInvariant()
    if ($yedeklenen.ContainsKey($anahtar)) { continue }

    if (-not $yedekVar) {
        [void](New-Item -ItemType Directory -Path $yedekKlasoru -Force)
        $yedekVar = $true
    }

    Copy-Item -LiteralPath $hedef.Hedef -Destination (Join-Path $yedekKlasoru (Split-Path -Leaf $hedef.Hedef)) -Force
    $yedeklenen[$anahtar] = $true
}

$islenen = 0
$toplamDegisen = 0
$bozuk = 0

foreach ($hedef in $hedefler) {
    if (-not (Test-Path -LiteralPath $hedef.Kaynak)) {
        Write-Host ("UYARI: Kaynak bulunamadı, atlanıyor: " + $hedef.Kaynak) -ForegroundColor Yellow
        continue
    }

    $dosyaDegisen = 0
    $basarili = Convert-Pak -Kaynak $hedef.Kaynak -Hedef $hedef.Hedef -Sozluk $sozluk -Degisen ([ref]$dosyaDegisen) -Bozuk ([ref]$bozuk)

    if ($basarili) {
        $islenen = $islenen + 1
        $toplamDegisen = $toplamDegisen + $dosyaDegisen
        Write-Host ("[TAMAM] " + (Split-Path -Leaf $hedef.Hedef) + " - değişen dize: " + $dosyaDegisen) -ForegroundColor Green
    }
    else {
        Write-Host ("[ATLANDI] " + (Split-Path -Leaf $hedef.Hedef)) -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Özet:"
Write-Host ("  İşlenen dosya: " + $islenen)
Write-Host ("  Değişen dize: " + $toplamDegisen)
Write-Host ("  Atlanan bozuk entry: " + $bozuk)

if ($yedekVar) {
    Write-Host ("  Yedek klasörü: " + $yedekKlasoru)
}
else {
    Write-Host "  Yedek klasörü: yok (yedeklenecek dosya bulunamadı)"
}

if ($islenen -eq 0) {
    Write-Host "HATA: Hiçbir dosya işlenemedi." -ForegroundColor Red
    exit 1
}
