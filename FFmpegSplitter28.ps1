param([switch]$SelfTest)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()
if (-not ('BpmDetector' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class BpmDetector
{
    // Reads raw mono 16-bit PCM and estimates the tempo. Returns 0 if it cannot.
    public static double Detect(string rawPath, int sampleRate)
    {
        byte[] bytes = File.ReadAllBytes(rawPath);
        int n = bytes.Length / 2;
        const int hop = 128;
        int frames = n / hop;
        if (frames < 400) return 0;

        // 1) Loudness envelope
        double[] env = new double[frames];
        for (int f = 0; f < frames; f++)
        {
            double sum = 0;
            int off = f * hop;
            for (int i = 0; i < hop; i++)
            {
                double s = BitConverter.ToInt16(bytes, (off + i) * 2) / 32768.0;
                sum += s * s;
            }
            env[f] = Math.Log(1.0 + 1000.0 * Math.Sqrt(sum / hop));
        }

        // 2) Onset strength (rising edges only)
        double[] onset = new double[frames];
        for (int f = 1; f < frames; f++)
        {
            double d = env[f] - env[f - 1];
            onset[f] = d > 0 ? d : 0;
        }

        // 3) Remove local average (~1 second window)
        double[] cs = new double[frames + 1];
        for (int i = 0; i < frames; i++) cs[i + 1] = cs[i] + onset[i];
        int w = (int)(sampleRate / (double)hop);
        double[] flat = new double[frames];
        for (int f = 0; f < frames; f++)
        {
            int lo = Math.Max(0, f - w);
            int hi = Math.Min(frames, f + w + 1);
            double mean = (cs[hi] - cs[lo]) / (hi - lo);
            double v = onset[f] - mean;
            flat[f] = v > 0 ? v : 0;
        }

        // 4) Autocorrelation over candidate tempos (70-180 BPM)
        double fps = sampleRate / (double)hop;
        double bestBpm = 0, bestScore = double.MinValue;
        for (double bpm = 70.0; bpm <= 180.0; bpm += 0.25)
        {
            double lag = fps * 60.0 / bpm;
            double score = Ac(flat, lag) + 0.5 * Ac(flat, 2.0 * lag) + 0.25 * Ac(flat, 4.0 * lag);
            double oct = Math.Log(bpm / 120.0, 2.0);
            score *= Math.Exp(-0.5 * oct * oct / (0.9 * 0.9));   // mild preference for common tempos
            if (score > bestScore) { bestScore = score; bestBpm = bpm; }
        }
        return Math.Round(bestBpm, 1);
    }

    private static double Ac(double[] x, double lag)
    {
        int li = (int)lag;
        double fr = lag - li;
        int n = x.Length - li - 1;
        if (n < 50) return 0;
        double sum = 0;
        for (int i = 0; i < n; i++)
            sum += x[i] * (x[i + li] * (1.0 - fr) + x[i + li + 1] * fr);
        return sum / n;
    }
}
'@ }  # BPM detection from BPM Changer v1.1.0
$ver = "v28"
$inv = [Globalization.CultureInfo]::InvariantCulture
$script:cmb = New-Object System.Collections.ArrayList
$ffLog = Join-Path $env:TEMP "ffsplit_bpm.log"
$script:bpmFile = $null; $script:bpmOut = $null; $script:clock = [Diagnostics.Stopwatch]::StartNew(); $script:tap = New-Object 'System.Collections.Generic.List[double]'
$script:audC = @{ mp3='libmp3lame'; m4a='aac'; aac='aac'; wav='pcm_s16le'; flac='flac'; opus='libopus'; ogg='libvorbis' }
$cfgDir = "$env:APPDATA\FFmpegSplitter"; $cfgFile = "$cfgDir\settings.json"; $preFile = "$cfgDir\presets.json"
$srcCache = @{}; $lenCache = @{}; $durCache = @{}; $script:nSkipped = 0
$script:files = @(); $script:cancel = $false; $script:presets = [ordered]@{}
$script:undoStack = New-Object System.Collections.ArrayList
$script:hist = New-Object System.Collections.ArrayList; $script:histTime = [datetime]::MinValue; $script:histSkip = $false; $script:histPrev = ""

$f = New-Object Windows.Forms.Form
$f.Text = "FFmpeg Splitter $ver"; $f.Size = '780,850'; $f.StartPosition = 'CenterScreen'

function L($t,$x,$y){ $l=New-Object Windows.Forms.Label; $l.Text=$t; $l.Location="$x,$y"; $l.AutoSize=$true; $f.Controls.Add($l) }
function LG($t,$x,$y){ $l=New-Object Windows.Forms.Label; $l.Text=$t; $l.Location="$x,$y"; $l.AutoSize=$true; $l.ForeColor="Gray"; $f.Controls.Add($l) }  # grey hint text
function T($v,$x,$y,$w){ $t=New-Object Windows.Forms.TextBox; $t.Text=$v; $t.Location="$x,$y"; $t.Width=$w; $f.Controls.Add($t); $t }
function C($items,$v,$x,$y,$w){ $c=New-Object Windows.Forms.ComboBox; $c.Items.AddRange($items); $c.Text=$v; $c.Location="$x,$y"; $c.Width=$w; $f.Controls.Add($c); $c }
function B($t,$x,$y,$w){ $b=New-Object Windows.Forms.Button; $b.Text=$t; $b.Location="$x,$y"; $b.Width=$w; $f.Controls.Add($b); $b }
function K($t,$v,$x,$y){ if($v -isnot [bool]){ throw "K '${t}': 2nd argument must be `$true or `$false" }; $k=New-Object Windows.Forms.CheckBox; $k.Text=$t; $k.Checked=$v; $k.Location="$x,$y"; $k.AutoSize=$true; $f.Controls.Add($k); $k }
function M($t){ [void][Windows.Forms.MessageBox]::Show($t) }

# ---- Files ----
L "Input video(s)" 15 18; $tIn = T "" 110 15 510; $bIn = B "Browse" 630 13 110
L "Output folder" 15 50;  $tOut = T "" 110 47 510; $bOut = B "Browse" 630 45 110

# ---- Encoder ----
L "Video codec" 15 85; $cCodec = C @('hevc_amf (AMD)','h264_amf (AMD)','av1_amf (AMD)','hevc_nvenc (NVIDIA)','h264_nvenc (NVIDIA)','av1_nvenc (NVIDIA)','libx265 (CPU)','libx264 (CPU)','libvpx-vp9 (CPU)') 'hevc_amf (AMD)' 100 82 145
L "-quality (AMD)" 255 85; $cQual = C @('quality','balanced','speed','(none)') 'quality' 340 82 75
L "-preset (CPU/NV)" 425 85; $cPreset = C @('ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow','(none)') 'medium' 520 82 75
L "Audio" 605 85; $cAud = C @('aac','libmp3lame','libopus','copy') 'aac' 645 82 80
L "-b:v" 15 120;      $tBv = T "10M" 110 117 80
L "-maxrate" 210 120; $tMax = T "12M" 275 117 80
L "-bufsize" 375 120; $tBuf = T "24M" 435 117 80
L "-b:a" 535 120;     $tBa = T "192k" 575 117 80
$kFast = K "-movflags +faststart" $true 15 147
$kY    = K "-y (overwrite)" $true 200 147
$kWait = K "-Wait (one after another)" $true 340 147
$kVis  = K "Show ffmpeg window" $true 540 147

$kCopy = K "Copy mode (no re-encode, instant)" $false 15 172
$kSrc  = K "Use source video bitrate" $false 255 172
$kSkip = K "Skip files that already exist" $false 430 172
$kOpen = K "Open folder + beep when done" $true 15 197
$kFix = K "Seek-friendly output" $false 565 197
L "-ss position" 255 200
$cSeek = C @('Before -i (fast)','After -i (accurate, slower)') 'Before -i (fast)' 340 197 210
$cSeek.DropDownStyle = 'DropDownList'; $cSeek.SelectedIndex = 0
L "Extra args" 15 230; $tExtra = T "" 110 227 630
$kLim = K "Keep each file under" $true 15 258
$tLim = T "1.9" 160 256 45
L "GB (Telegram limit is 2 GB)" 212 259
$kSrc.Add_CheckedChanged({ $tBv.Enabled = -not $kSrc.Checked })

# ---- Segment generators ----
L "Chunk (min)" 15 293; $tChunk = T "15" 90 290 40
L "Name prefix" 145 293; $tPre = T "Game Play" 218 290 110
$bGen  = B "Generate by minutes" 345 288 170
$bAuto = B "Auto split by size" 525 288 170
L "Preset" 15 326; $cPre = C @() "" 65 323 200
$bSavePre = B "Save preset" 275 322 100
$bDelPre  = B "Delete preset" 380 322 100
L "Output format" 15 356; $cExt = C @('mp4','mkv','mov','avi','ts','m4v','flv','webm') 'mp4' 100 353 65
$cExt.DropDownStyle = 'DropDownList'; $cExt.SelectedIndex = 0
(New-Object Windows.Forms.ToolTip).SetToolTip($cExt,"Converts to this container. webm needs libvpx-vp9 + libopus; avi/ts/flv/mkv/mov/mp4 work with the H.264/HEVC encoders.")
$kComp = K "Compress" $false 175 355
$bComp = B "Compress..." 258 352 95
$bGif = B "GIF..." 358 352 60
$bFolder = B "Add folder..." 423 352 100
$kExact = K "Exact size mode (cut at the GB limit)" $false 533 355
$bAudio = B "Audio edit..." 640 168 105
$bTools = B "More tools..." 560 254 185
(New-Object Windows.Forms.ToolTip).SetToolTip($tPre,"Tokens: {name} = source file name, {n} = number, e.g. {name}_{n}")

$g = New-Object Windows.Forms.DataGridView
$g.Location = '15,385'; $g.Size = '735,185'; $g.AllowUserToAddRows = $true
$g.AutoSizeColumnsMode = 'Fill'; $g.RowHeadersVisible = $true; $g.RowHeadersWidth = 30
$g.AllowUserToDeleteRows = $true; $g.SelectionMode = 'RowHeaderSelect'; $g.MultiSelect = $true
[void]$g.Columns.Add('s','Start (hh:mm:ss)'); [void]$g.Columns.Add('e','End (hh:mm:ss)'); [void]$g.Columns.Add('n','Output name'); [void]$g.Columns.Add('i','Input file (blank = main input)')
$g.Columns[0].FillWeight = 15; $g.Columns[1].FillWeight = 15; $g.Columns[2].FillWeight = 28; $g.Columns[3].FillWeight = 42
$f.Controls.Add($g)

$bPrev = B "Preview commands" 15 580 130
$bRun  = B "Run" 150 580 90; $bRun.BackColor = 'LightGreen'
$bCancel = B "Cancel" 245 580 80; $bCancel.Enabled = $false
$bDel = B "Delete selected" 335 580 110
$bClr = B "Clear all" 450 580 80
$bUndo = B "Undo" 535 580 70
$kEdit = K "Run edited commands" $false 615 583
$bUndoEdit = B "Clear edit" 555 630 95
$bUndoBox = B "Undo" 655 630 95
(New-Object Windows.Forms.ToolTip).SetToolTip($bUndoEdit,"Throws away ALL your edits and puts the commands back as Preview made them. Use Undo to step back one edit at a time.")
$bUndoEdit.Add_Click({
  if($null -ne $script:boxOrig){ $script:histTime = [datetime]::MinValue; $box.Text = $script:boxOrig; $status.Text = "Edits cleared: the commands are back as Preview made them. Undo brings your edits back." }
  else { $status.Text = "Nothing to restore yet - click Preview first." }
})
(New-Object Windows.Forms.ToolTip).SetToolTip($kEdit,"Click Preview, edit the commands in the box below, tick this, then Run. Only lines like Start-Process ffmpeg -ArgumentList '...' are run.")
$pb = New-Object Windows.Forms.ProgressBar; $pb.Location = '15,612'; $pb.Size = '735,18'; $f.Controls.Add($pb)
$status = New-Object Windows.Forms.Label; $status.Location = '15,634'; $status.AutoSize = $true; $f.Controls.Add($status)
$box = New-Object Windows.Forms.TextBox
$box.Multiline = $true; $box.ScrollBars = 'Both'; $box.WordWrap = $false; $box.Location = '15,658'; $box.Size = '735,130'; $box.Font = 'Consolas,9'
$f.Controls.Add($box)
# Undo like Ctrl+Z, one step at a time: a burst of typing counts as one step (shortcut: keeps the last 100 steps)
$box.Add_TextChanged({
  if(-not $script:histSkip -and ([datetime]::Now - $script:histTime).TotalMilliseconds -gt 800){ [void]$script:hist.Add($script:histPrev); if($script:hist.Count -gt 100){ $script:hist.RemoveAt(0) } }
  if(-not $script:histSkip){ $script:histTime = [datetime]::Now }
  $script:histPrev = $box.Text
})
$bUndoBox.Add_Click({
  if($script:hist.Count -eq 0){ $status.Text = "Nothing to undo."; return }
  $t = $script:hist[$script:hist.Count - 1]; $script:hist.RemoveAt($script:hist.Count - 1)
  $script:histSkip = $true; $box.Text = $t; $script:histSkip = $false; $script:histTime = [datetime]::MinValue
  $status.Text = "Undone ($($script:hist.Count) more step(s) left)."
})
$box.Add_KeyDown({ if($_.Control -and $_.KeyCode -eq 'Z'){ $bUndoBox.PerformClick(); $_.SuppressKeyPress = $true } })

# ---- Helpers ----
function Probe($file,$q){ try { (& ffprobe -v error @q -of csv=p=0 "$file" | Select-Object -First 1) } catch {} }
function Get-Dur($file){ $v = Probe $file @('-show_entries','format=duration'); if("$v" -match '^[\d.]+$'){ [double]$v } else { $null } }
function Get-SrcBitrate($file){
  foreach($q in @(@('-select_streams','v:0','-show_entries','stream=bit_rate'), @('-show_entries','format=bit_rate'))){
    $v = Probe $file $q; if("$v" -match '^\d+$'){ return [long]$v } }
  return $null
}
function TS($sec){ [TimeSpan]::FromSeconds([math]::Round($sec)).ToString('hh\:mm\:ss') }
function Parse-Rate($s){
  if("$s".Trim() -match '^(\d+(\.\d+)?)\s*([kKmM]?)$'){
    $m = switch($Matches[3].ToLower()){ 'k' {1000} 'm' {1000000} default {1} }
    return [long]([double]$Matches[1] * $m) }
  return $null
}
function Set-Files($paths){
  $script:files = @($paths); $srcCache.Clear(); $lenCache.Clear(); $durCache.Clear()
  $tIn.Text = if($script:files.Count -gt 1){ "$($script:files.Count) files: " + (Split-Path $script:files[0] -Leaf) + " ..." } else { $script:files[0] }
  if(-not $tOut.Text){ $tOut.Text = Split-Path $script:files[0] }
  Fill-Default
}
function Input-Of($row){
  $v = [string]$row.Cells[3].Value
  if($v){ $v } elseif($script:files.Count){ $script:files[0] } else { $tIn.Text }
}

$bIn.Add_Click({ $d=New-Object Windows.Forms.OpenFileDialog; $d.Multiselect=$true; $d.Filter="Video|*.mp4;*.mkv;*.mov;*.avi;*.webm|All|*.*"; if($d.ShowDialog() -eq 'OK'){ Set-Files $d.FileNames } })
$bOut.Add_Click({ $d=New-Object Windows.Forms.FolderBrowserDialog; if($d.ShowDialog() -eq 'OK'){ $tOut.Text=$d.SelectedPath } })
$tIn.Add_Leave({ if($tIn.Text -and (Test-Path -LiteralPath $tIn.Text)){ $script:files = @($tIn.Text) } })
$f.AllowDrop = $true; $tIn.AllowDrop = $true
$enter = { if($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)){ $_.Effect='Copy' } }
$drop  = { $p = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if($p){ Set-Files $p } }
$f.Add_DragEnter($enter); $f.Add_DragDrop($drop); $tIn.Add_DragEnter($enter); $tIn.Add_DragDrop($drop)

# ---- Undo ----
function Save-Undo {
  $snap = @()
  foreach($r in $g.Rows){ if(-not $r.IsNewRow){ $snap += ,@($r.Cells[0].Value,$r.Cells[1].Value,$r.Cells[2].Value,$r.Cells[3].Value) } }
  if($snap.Count -gt 0){ [void]$script:undoStack.Add($snap) }
}
$bUndo.Add_Click({
  if($script:undoStack.Count -eq 0){ $status.Text = "Nothing to undo."; return }
  $snap = $script:undoStack[$script:undoStack.Count-1]; $script:undoStack.RemoveAt($script:undoStack.Count-1)
  $g.Rows.Clear(); foreach($row in $snap){ [void]$g.Rows.Add($row[0],$row[1],$row[2],$row[3]) }
  $status.Text = "Restored $($snap.Count) segment(s)."
})
$bDel.Add_Click({
  Save-Undo; $rows = @()
  foreach($r in $g.SelectedRows){ if(-not $r.IsNewRow){ $rows += $r } }
  foreach($c in $g.SelectedCells){ $r=$g.Rows[$c.RowIndex]; if(-not $r.IsNewRow -and $rows -notcontains $r){ $rows += $r } }
  foreach($r in $rows){ $g.Rows.Remove($r) }
})
$bClr.Add_Click({
  if($g.Rows.Count -le 1){ return }
  if([Windows.Forms.MessageBox]::Show("Remove all segments? You can use Undo to bring them back.","Clear all",'YesNo','Question') -eq 'Yes'){ Save-Undo; $g.Rows.Clear() }
})

# ---- Generate segments (all files, numbering continues across files) ----
function Add-Segments($mode){
  if(-not $script:files.Count){ M "Choose or drop a video first."; return }
  $step = $null; $gb = $null
  if($mode -eq 'min'){ try { $step = [double]$tChunk.Text * 60 } catch {}; if(-not $step -or $step -lt 1){ M "Chunk (min) must be at least 0.02. Use a number like 15."; return } }
  elseif($mode -eq 'size'){ try { $gb = [double]$tLim.Text } catch {}; if(-not $gb -or $gb -le 0){ M "Enter a size limit in GB (like 1.9)."; return } }
  Save-Undo; $g.Rows.Clear(); $i = 1
  foreach($file in $script:files){
    $d = Get-Dur $file
    if(-not $d){ M "Couldn't read the length of $(Split-Path $file -Leaf). Is ffprobe in PATH?"; continue }
    if($mode -eq 'size'){
      $len = (Get-Item -LiteralPath $file).Length
      $parts = [math]::Max(1,[math]::Ceiling($len / ($gb * 1e9 * 0.95))); $st = $d / $parts
    } elseif($mode -eq 'whole'){ $st = $d } else { $st = $step }
    if($d / $st -gt 500){ M "More than 500 segments for $(Split-Path $file -Leaf). Use a bigger chunk."; continue }
    $s = 0.0
    while($s -lt $d - 0.5){
      $e = [math]::Min($s + $st, $d)
      [void]$g.Rows.Add((TS $s),(TS $e),(Row-Name $file $i $mode),$file); $s = $e; $i++
    }
  }
  $status.Text = "Created $($i-1) segment(s)."
}
$bGen.Add_Click({ Add-Segments 'min' })
$bAuto.Add_Click({ Add-Segments 'size' })

# ---- Settings + presets ----
function Get-Settings {
  @{ codec=$cCodec.Text; qual=$cQual.Text; preset=$cPreset.Text; ext=$cExt.Text; comp=$kComp.Checked; aud=$cAud.Text; bv=$tBv.Text; maxr=$tMax.Text; buf=$tBuf.Text; ba=$tBa.Text
     fast=$kFast.Checked; y=$kY.Checked; wait=$kWait.Checked; vis=$kVis.Checked; copy=$kCopy.Checked; src=$kSrc.Checked
     skip=$kSkip.Checked; open=$kOpen.Checked; fix=$kFix.Checked; lim=$kLim.Checked; limv=$tLim.Text; chunk=$tChunk.Text; pre=$tPre.Text
     extra=$tExtra.Text; seek=$cSeek.SelectedIndex; out=$tOut.Text }
}
function Apply-Settings($h){
  $tx = @{ codec=$cCodec;qual=$cQual;preset=$cPreset;ext=$cExt;aud=$cAud;bv=$tBv;maxr=$tMax;buf=$tBuf;ba=$tBa;extra=$tExtra;limv=$tLim;chunk=$tChunk;pre=$tPre }
  foreach($k in $tx.Keys){ if($null -ne $h.$k){ $tx[$k].Text = [string]$h.$k } }
  $cb = @{ fast=$kFast;y=$kY;wait=$kWait;vis=$kVis;copy=$kCopy;src=$kSrc;skip=$kSkip;open=$kOpen;lim=$kLim;fix=$kFix;comp=$kComp }
  foreach($k in $cb.Keys){ if($null -ne $h.$k){ $cb[$k].Checked = [bool]$h.$k } }
  if($null -ne $h.seek){ $cSeek.SelectedIndex = [int]$h.seek }
}
function Load-Presets {
  $script:presets = [ordered]@{}
  if(Test-Path $preFile){ try { $o = Get-Content $preFile -Raw | ConvertFrom-Json; foreach($p in $o.PSObject.Properties){ $script:presets[$p.Name] = $p.Value } } catch {} }
  $cPre.Items.Clear(); foreach($k in $script:presets.Keys){ [void]$cPre.Items.Add($k) }
}
function Write-Presets { New-Item -ItemType Directory -Force $cfgDir | Out-Null; $script:presets | ConvertTo-Json -Depth 4 | Set-Content $preFile }
$bSavePre.Add_Click({
  $n = [Microsoft.VisualBasic.Interaction]::InputBox("Preset name (e.g. Telegram 8M):","Save preset",$cPre.Text)
  if($n){ $h = Get-Settings; $h.Remove('out'); $script:presets[$n] = $h; Write-Presets; Load-Presets; $cPre.Text = $n; $status.Text = "Saved preset '$n'." }
})
$bDelPre.Add_Click({ if($script:presets.Contains($cPre.Text)){ $script:presets.Remove($cPre.Text); Write-Presets; Load-Presets; $cPre.Text = "" } })
$cPre.Add_SelectedIndexChanged({ if($script:presets.Contains($cPre.Text)){ Apply-Settings $script:presets[$cPre.Text]; $status.Text = "Loaded preset '$($cPre.Text)'." } })
Load-Presets

# ---- Build commands ----
function CodecName { ($cCodec.Text -replace '\s*\(.*\)\s*$','').Trim() }
function Sec($v){ try { $x = [string]$v; if($x -match '^[\d.]+$'){ [double]::Parse($x,$inv) } else { [TimeSpan]::Parse($x).TotalSeconds } } catch { 0 } }
function Vol-Filter($t){  # "+6" / "-3" = dB, "1.5x" = multiplier
  $v = 0.0
  if("$t" -match '^\s*([\d.]+)\s*x\s*$'){ return "volume=$($Matches[1])" }
  if([double]::TryParse("$t",'Float',$inv,[ref]$v) -and $v -ne 0){ return "volume=$($v.ToString($inv))dB" }
}
# Filter chain for noise, volume and mute ranges. off = seconds to subtract (filter time is segment-relative when -ss is before -i).
function Audio-Filter($segS,$segE,$off){
  $p = @()
  if($kNoise.Checked){ $p += 'afftdn' }  # shortcut: denoise only, ffmpeg can't separate voice from game sound
  $vf = Vol-Filter $tVol.Text; if($vf){ $p += $vf }
  $b = @()
  foreach($rg in ($tMute.Text -split ',')){
    if($rg -match '^\s*([\d:.]+)\s*-\s*([\d:.]+)\s*$'){
      $lo = [math]::Max((Sec $Matches[1]),$segS); $hi = [math]::Min((Sec $Matches[2]),$segE)
      if($hi -gt $lo){ $b += "between(t,$(($lo-$off).ToString($inv)),$(($hi-$off).ToString($inv)))" }
    }
  }
  if($b){ $p += "volume=enable='$($b -join '+')':volume=0" }
  $p -join ','
}
# Rows of the "Add audio at" table, clipped to one segment (each row has its own file, range, Mix/Mute and volume).
function Ins-Rows($segS,$segE){
  foreach($r in $gIns.Rows){
    if($r.IsNewRow){ continue }
    $rg = [string]$r.Cells[0].Value; $file = [string]$r.Cells[1].Value
    if($rg -match '^\s*([\d:.]+)\s*-\s*([\d:.]+)\s*$' -and $file -and (Test-Path -LiteralPath $file)){
      $lo = [math]::Max((Sec $Matches[1]),$segS); $hi = [math]::Min((Sec $Matches[2]),$segE)
      if($hi -gt $lo){ [pscustomobject]@{ Lo = $lo; Hi = $hi; File = $file; Mute = ([string]$r.Cells[2].Value -like 'Mute*'); Vol = (Vol-Filter ([string]$r.Cells[3].Value)) } }
    }
  }
}
# Extra audio: table rows (different files at exact times), or one file that replaces / mixes with the original.
function Audio-Extra($segS,$segE,$off,$af,$noA){
  if($noA){ return $null }
  $ins = @(Ins-Rows $segS $segE)
  $file = $tRep.Text
  $wantMain = $file -and (Test-Path -LiteralPath $file) -and $cMode.Text -in 'Replace with file','Mix with original'
  if(-not $ins.Count -and -not $wantMain){ return $null }
  if($ins.Count){
    # inputs 1..K are the row files; Mute rows silence the original during their range
    $inp = ''; foreach($x in $ins){ $inp += " -i `"$($x.File)`"" }
    $mb = @($ins | Where-Object { $_.Mute } | ForEach-Object { "between(t,$(($_.Lo-$off).ToString($inv)),$(($_.Hi-$off).ToString($inv)))" })
    $chain = @(); if($af){ $chain += $af }; if($mb.Count){ $chain += "volume=enable='$($mb -join '+')':volume=0" }
    $fc = '[0:a]' + $(if($chain.Count){ $chain -join ',' } else { 'anull' }) + '[o];'; $mix = '[o]'; $k = 0
    foreach($x in $ins){
      $k++; $v = if($x.Vol){ $x.Vol + ',' } else { '' }
      $fc += "[$($k):a]${v}atrim=duration=$(($x.Hi-$x.Lo).ToString($inv)),adelay=$([long](($x.Lo-$off)*1000)):all=1[x$k];"; $mix += "[x$k]"
    }
    $fc += $mix + 'amix=inputs=' + ($ins.Count + 1) + ':duration=first:normalize=0[aout]'
    return [pscustomobject]@{ Inp = $inp; Cmd = "-filter_complex `"$fc`" -map 0:v:0 -map `"[aout]`"" }
  }
  $io = ''; if($kLoopA.Checked){ $io += ' -stream_loop -1' }
  if($tRs.Text){ $io += " -ss $($tRs.Text)" }; if($tRe.Text){ $io += " -to $($tRe.Text)" }
  $inp = "$io -i `"$file`""
  $nvRaw = Vol-Filter $tAddVol.Text; $nv = if($nvRaw){ $nvRaw } else { 'anull' }
  $ov = if($af){ $af } else { 'anull' }
  if($cMode.Text -eq 'Mix with original'){
    $fc = '[0:a]' + $ov + '[o];[1:a]' + $nv + '[n];[o][n]amix=inputs=2:duration=first:normalize=0[aout]'
    return [pscustomobject]@{ Inp = $inp; Cmd = "-filter_complex `"$fc`" -map 0:v:0 -map `"[aout]`"" }
  }
  # replace: apad + -shortest = the audio stops with the video (silence pads a short file); looping replaces apad
  $chain = @(@($nvRaw, $af) | Where-Object { $_ }); if(-not $kLoopA.Checked){ $chain += 'apad' }
  [pscustomobject]@{ Inp = $inp; Cmd = $(if($chain.Count){ "-af `"$($chain -join ',')`" " } else { "" }) + "-map 0:v:0 -map 1:a:0 -shortest" }
}
function Aud-Args($af,$enc){
  $c = $cAud.Text; if($c -eq 'copy' -and ($af -or $enc)){ $c = 'aac' }  # filters need re-encoded audio
  $s = " -c:a $c"
  if($c -ne 'copy' -and $tBa.Text){ $s += " -b:a $($tBa.Text)" }
  if($af){ $s += " -af `"$af`"" }
  $s
}
function Atempo($x){ if($x -gt 2){ "atempo=2,atempo=$(($x/2).ToString($inv))" } elseif($x -lt 0.5){ "atempo=0.5,atempo=$(($x/0.5).ToString($inv))" } else { "atempo=$($x.ToString($inv))" } }
# Name tokens: {name} = source file name, {n} = counter. Batch rows default to the source name.
function Row-Name($file,$i,$mode){  # blank prefix = <name>_copy ; {name} {n} tokens ; otherwise prefix + number
  $b = [IO.Path]::GetFileNameWithoutExtension($file); $p = $tPre.Text
  if($p -match '\{'){ $p.Replace('{name}',$b).Replace('{n}',"$i") }
  elseif(-not $p.Trim()){ if($mode -in 'whole','fill'){ "${b}_copy" } else { "${b}_copy$i" } }
  elseif($mode -eq 'whole'){ $b } else { "$p$i" }
}
# One confirm + sequential ffmpeg run for simple jobs (@{Args;Out}).
$check = [string][char]0x2714
function Finish($text){  # checkmark + prompt, then the bar goes back to 0
  $pb.Value = 100; $status.Text = "$check $text"; [System.Media.SystemSounds]::Asterisk.Play()
  M "$check $text"
  $pb.Value = 0
}
function Sync-Codec {  # GPU (AMD) uses -quality, CPU uses -preset (NVIDIA: p1-p7 presets)
  $c = CodecName; $nv = $c -like '*_nvenc'
  $cQual.Enabled = $c -like '*_amf'; $cPreset.Enabled = ($c -in 'libx264','libx265') -or $nv
  $items = if($nv){ 'p1','p2','p3','p4','p5','p6','p7','(none)' } else { 'ultrafast','superfast','veryfast','faster','fast','medium','slow','slower','veryslow','(none)' }
  if(-not $cPreset.Items.Contains($items[0])){ $cPreset.Items.Clear(); $cPreset.Items.AddRange($items); $cPreset.Text = $(if($nv){ 'p5' } else { 'medium' }) }
}
function Exact-Info($file,$bytes){  # estimated source/output size and number of parts
  $td = Get-DurC $file; $est = $null
  $ab = Parse-Rate $tBa.Text; if(-not $ab -or $cAud.Text -eq 'copy'){ $ab = 192000 }
  if($kCopy.Checked -and -not $kComp.Checked){ $est = (Get-Item -LiteralPath $file).Length }
  elseif($td){
    if(-not $srcCache.ContainsKey($file)){ $srcCache[$file] = Get-SrcBitrate $file }
    $b = if($kSrc.Checked){ $srcCache[$file] } else { Parse-Rate $tBv.Text }
    if($kComp.Checked){ $b = Parse-Rate $tCBit.Text }
    if($b){ $est = ($b + $ab) * $td / 8 }
  }
  [pscustomobject]@{ Total = $td; Est = $est; Parts = $(if($est){ [math]::Max(1,[math]::Ceiling($est / $bytes)) } else { 0 }) }
}
function Exact-Preview($bytes){
  $out = @("# Exact size mode: each part stops at the size limit and the next part starts where the previous one ended. Start times are estimates; real ones are known while it runs.")
  $i = 1
  foreach($file in $script:files){
    $x = Exact-Info $file $bytes
    if(-not $x.Est -or -not $x.Total){ $out += "# $(Split-Path $file -Leaf): can't estimate (tick source bitrate or fill -b:v)"; continue }
    $step = $x.Total * $bytes / $x.Est
    for($k = 0; $k -lt [math]::Min($x.Parts, 25); $k++){
      $row = [pscustomobject]@{ IsNewRow = $false; Cells = @(
        [pscustomobject]@{ Value = ($k * $step).ToString('0.###',$inv) }, [pscustomobject]@{ Value = $x.Total.ToString('0.###',$inv) },
        [pscustomobject]@{ Value = (Row-Name $file ($i + $k) 'min') }, [pscustomobject]@{ Value = $file }) }
      $c = (Build-Commands @($row) $bytes)[0]
      $out += Preview-Line "$($c.Pre)" $c.Out $null $true
    }
    if($x.Parts -gt 25){ $out += "# ... and $($x.Parts - 25) more part(s)" }
    $i += $x.Parts
  }
  $out
}
function Get-DurC($file){ if(-not $durCache.ContainsKey($file)){ $durCache[$file] = Get-Dur $file }; $durCache[$file] }
function Table-Rows { @($g.Rows | Where-Object { -not $_.IsNewRow -and ($_.Cells[0].Value -or $_.Cells[1].Value -or $_.Cells[2].Value -or $_.Cells[3].Value) }) }
function Fill-Default {  # one table row per input file: Start 00:00:00, End = video length, name and input path filled in
  Save-Undo; $g.Rows.Clear(); $i = 0
  foreach($file in $script:files){
    $i++
    $d = if($script:files.Count -le 50){ Get-DurC $file }  # shortcut: with more than 50 files End stays blank (= to the end) so the app does not probe every file
    [void]$g.Rows.Add('00:00:00', $(if($d){ TS $d } else { '' }), (Row-Name $file $i 'fill'), $file)
  }
}
function Preview-Line($pre,$out,$est,$wait){
  $arg = "$pre `"$out`"".Replace("'","''")  # doubled ' so the pasted line survives names like Bob's game.mp4
  "Start-Process ffmpeg -ArgumentList '$arg'" + $(if($wait){ ' -Wait' }) + $(if($est){ "   # ~$(GB $est)" })
}
function Show-Text($title,$text){
  $w = New-Object Windows.Forms.Form; $w.Text = $title; $w.Size = '700,500'; $w.StartPosition = 'CenterParent'
  $t = New-Object Windows.Forms.TextBox; $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Both'; $t.WordWrap = $false; $t.Dock = 'Fill'; $t.Font = 'Consolas,9'; $t.Text = $text
  $w.Controls.Add($t); $w.Add_Shown({ $this.Controls[0].Select(0,0) }); [void]$w.ShowDialog($f)
}
function Gif-Filter($fps,$w,$orig,$fast,$comp,$transp,$static){
  $sc = if($orig){ '' } else { ",scale=$($w):-1" + $(if($fast){ '' } else { ':flags=lanczos' }) }
  $colors = [int][math]::Max(32, 256 - [math]::Round($comp * 2.24))  # compression slider: fewer colours = smaller GIF
  $pg = "palettegen=max_colors=$colors" + $(if($static){ ':stats_mode=diff' }) + $(if($transp){ ':reserve_transparent=1' })
  $o = @(); if($fast -or $comp -gt 0){ $o += 'dither=bayer','bayer_scale=5' }
  if($comp -gt 10){ $o += 'diff_mode=rectangle' }; if($transp){ $o += 'alpha_threshold=128' }
  $pu = 'paletteuse' + $(if($o){ '=' + ($o -join ':') })
  "fps=$fps$sc,split[s0][s1];[s0]${pg}[p];[s1][p]$pu"
}
function Frame-Dir { if($tFrameOut.Text){ $tFrameOut.Text } else { & $outDir } }
function Show-Shot($file,$t,$saveDir,$owner){  # one frame in a small window, with Save as...
  $img = Join-Path $env:TEMP "ffsplit_shot.jpg"; Remove-Item $img -ErrorAction SilentlyContinue
  Start-Process ffmpeg -ArgumentList "-ss $t -i `"$file`" -frames:v 1 -vf scale=960:-2 -q:v 3 -y `"$img`"" -Wait -WindowStyle Hidden
  if(-not (Test-Path $img)){ M "No frame at $t (is it past the end of the video?)"; return }
  $w = New-Object Windows.Forms.Form; $w.Text = "Quick shot - $(Split-Path $file -Leaf) at $t"; $w.Size = '1000,640'; $w.StartPosition = 'CenterParent'
  $pic = New-Object Windows.Forms.PictureBox; $pic.Dock = 'Fill'; $pic.SizeMode = 'Zoom'
  $pic.Image = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (,[IO.File]::ReadAllBytes($img))))  # from memory so the temp file is never locked
  $sv = New-Object Windows.Forms.Button; $sv.Text = "Save as..."; $sv.Dock = 'Bottom'; $sv.Height = 34
  $name = [IO.Path]::GetFileNameWithoutExtension($file) + "_" + ($t -replace '[:.]','-') + ".jpg"
  $sv.Add_Click({
    $d = New-Object Windows.Forms.SaveFileDialog; $d.Filter = "JPEG|*.jpg"; $d.FileName = $name; if($saveDir){ $d.InitialDirectory = $saveDir }
    if($d.ShowDialog() -eq 'OK'){ Copy-Item -LiteralPath $img $d.FileName -Force }
  }.GetNewClosure())
  $w.Controls.Add($pic); $w.Controls.Add($sv); [void]$w.ShowDialog($owner)
}
# Waits for ffmpeg, keeps the window alive, fills the bar from $lo to $hi (0-100), and Cancel kills it.
function Wait-Ffmpeg($proc,$tmp,$dur,$lo,$hi){
  while(-not $proc.HasExited){
    Start-Sleep -Milliseconds 300; [Windows.Forms.Application]::DoEvents()
    if($script:cancel){ try { $proc.Kill() } catch {}; return }
    try {
      $t = Get-Content $tmp -ErrorAction Stop | Select-String 'out_time_us=(\d+)' | Select-Object -Last 1
      if($t -and $dur -gt 0){ $pb.Value = [int]($lo + ($hi - $lo) * [math]::Min(1, [double]$t.Matches[0].Groups[1].Value / 1e6 / $dur)) }
    } catch {}
  }
}
# Edited commands: only lines in the preview form  Start-Process ffmpeg -ArgumentList '...'  are accepted.
function Parse-Edited($lines){
  foreach($l in $lines){
    if($l -match "^\s*Start-Process\s+ffmpeg\s+-ArgumentList\s+'(.*)'(\s+-Wait)?\s*(#.*)?$"){ $Matches[1].Replace("''","'") }
    else { throw "Can't read this line (keep the form Start-Process ffmpeg -ArgumentList '...'):`n$l" }
  }
}
function Set-Box($t){ $script:hist.Clear(); $script:histSkip = $true; $box.Text = $t; $script:histSkip = $false; $script:boxOrig = $t }  # remembers what Preview generated, for Undo edit
function Run-Edited {
  if($kExact.Checked){ M "Untick Exact size mode first: its later parts start where the previous one ended, which edited commands can't do."; return }
  $lines = @($box.Lines | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') })
  if(-not $lines.Count){ M "The box is empty. Click Preview commands, edit the text, then tick Run edited commands."; return }
  try { $cmds = @(Parse-Edited $lines) } catch { M $_.Exception.Message; return }
  if([Windows.Forms.MessageBox]::Show("Run $($cmds.Count) edited command(s) exactly as written in the box? Size and overwrite checks are skipped.`n`nStart?","Confirm",'YesNo','Question') -ne 'Yes'){ return }
  $script:cancel = $false; $bRun.Enabled = $false; $bCancel.Enabled = $true; $pb.Value = 0; $n = 0
  foreach($a in $cmds){
    if($script:cancel){ break }
    $n++; $status.Text = "Running edited command $n of $($cmds.Count)..."
    $p = @{ FilePath = 'ffmpeg'; PassThru = $true; ArgumentList = "-nostdin $a" }  # -nostdin: never wait on an overwrite question
    if(-not $kVis.Checked){ $p.WindowStyle = 'Hidden' }
    Wait-Ffmpeg (Start-Process @p) $null 0 0 0
    $pb.Value = [int](100 * $n / $cmds.Count)
  }
  $bRun.Enabled = $true; $bCancel.Enabled = $false; $kEdit.Checked = $false
  if($script:cancel){ $pb.Value = 0; $status.Text = "Cancelled. The last file may be incomplete - delete it."; return }
  Finish "Finished encoding all videos: $n edited command(s) done."
}
function Run-Jobs($label,$jobs){
  $jobs = @($jobs | Where-Object { $kY.Checked -or -not (Test-Path -LiteralPath $_.Out) })
  if(-not $jobs.Count){ M "Nothing to do (outputs already exist and -y is off)."; return }
  Set-Box (@($jobs | ForEach-Object { Preview-Line "$($_.Args) -y" $_.Out $null $true }) -join "`r`n`r`n")
  if([Windows.Forms.MessageBox]::Show("$label : $($jobs.Count) file(s), first:`n$($jobs[0].Out)`n`nStart?","Confirm",'YesNo','Question') -ne 'Yes'){ return }
  foreach($d in $dlg,$dlg2,$dlgG,$dlgC){ if($d.Visible){ $d.DialogResult = 'OK' } }  # close the open window only after you confirm
  $tmp = Join-Path $env:TEMP "ffsplit_progress.txt"; $n = 0
  $script:cancel = $false; $bRun.Enabled = $false; $bCancel.Enabled = $true; $pb.Value = 0
  foreach($j in $jobs){
    if($script:cancel){ break }
    $n++; $status.Text = "$label $n of $($jobs.Count)..."
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $d0 = Split-Path $j.Out; if($d0 -and -not (Test-Path $d0)){ [void](New-Item -ItemType Directory -Force $d0) }
    $p = @{ FilePath = 'ffmpeg'; PassThru = $true; ArgumentList = "$($j.Args) -y -progress `"$tmp`" -nostats `"$($j.Out)`"" }
    if(-not $kVis.Checked){ $p.WindowStyle = 'Hidden' }
    # shortcut: jobs without a Dur (merge, frames, extract) show no bar movement, only the status text
    Wait-Ffmpeg (Start-Process @p) $tmp $j.Dur (100 * ($n-1) / $jobs.Count) (100 * $n / $jobs.Count)
    if($j.Lossy -and -not $script:cancel -and (Get-Command gifsicle -ErrorAction SilentlyContinue)){ Start-Process gifsicle -ArgumentList "-O3 --lossy=$($j.Lossy) -b `"$($j.Out)`"" -Wait -WindowStyle Hidden }  # real lossy LZW
  }
  $bRun.Enabled = $true; $bCancel.Enabled = $false
  if($script:cancel){ $pb.Value = 0; $status.Text = "Cancelled. The last file may be incomplete - delete it."; return }
  Finish "$label finished: $n file(s) done."
}
function GB($b){ "{0:N2} GB" -f ($b / 1e9) }
function Build-Commands($rowsOverride = $null, $fsBytes = 0) {
  $list = @(); $warned = $false; $warnedRep = $false
  $rows = if($rowsOverride){ $rowsOverride } else { Table-Rows }
  if(-not $rows.Count -and -not $rowsOverride){  # empty table = entire video of each input; _out keeps it from overwriting the input
    $i = 0
    $rows = @($script:files | ForEach-Object {
      $i++; $nm = Row-Name $_ $i 'fill'
      [pscustomobject]@{ IsNewRow = $false; Cells = @([pscustomobject]@{ Value = '' }, [pscustomobject]@{ Value = '' }, [pscustomobject]@{ Value = $nm }, [pscustomobject]@{ Value = $_ }) } })
  }
  foreach($r in $rows){
    $in = Input-Of $r
    $isAudio = $in -match '\.(mp3|m4a|aac|wav|flac|opus|ogg|wma)$'  # audio-only input: skip every video option
    $name = [string]$r.Cells[2].Value; if(-not $name){ $name = "Output$($list.Count+1)" }
    $ext = $(if($isAudio){ $cFmt.Text } else { $cExt.Text }); if(-not $name.ToLower().EndsWith(".$ext")){ $name += ".$ext" }
    $out = if($tOut.Text){ Join-Path $tOut.Text $name } else { $name }
    $s0 = [string]$r.Cells[0].Value; $e0 = [string]$r.Cells[1].Value  # blank start = from the beginning, blank end = to the end
    $times = (@($(if($s0){ "-ss $s0" }), $(if($e0){ "-to $e0" })) | Where-Object { $_ }) -join ' '
    $ss = if($s0){ Sec $s0 } else { 0 }; $se = if($e0){ Sec $e0 } else { 1e9 }
    $af = Audio-Filter $ss $se $(if($cSeek.SelectedIndex -eq 0){ $ss } else { 0 })
    if($isAudio){
      $a = "$times -i `"$in`" -vn -c:a $($script:audC[$ext])"
      if($ext -notin 'wav','flac' -and $tBa.Text){ $a += " -b:a $($tBa.Text)" }
      $a += " -ar 48000 -ac 2"
      if($af){ $a += " -af `"$af`"" }
      if($tExtra.Text){ $a += " $($tExtra.Text)" }
      if($kY.Checked){ $a += " -y" }
      $tt = if($e0){ $se } else { Get-DurC $in }
      $list += [pscustomobject]@{ Pre = $a; Out = $out; In = $in; Dur = $(if($tt){ $tt - $ss } else { 0 }); Est = $null }
      continue
    }
    $spd = 1.0; if(-not [double]::TryParse($tSpeed.Text,'Float',$inv,[ref]$spd) -or $spd -lt 0.25 -or $spd -gt 4){ $spd = 1.0 }
    if($spd -ne 1){ $af = (@($af, (Atempo $spd)) | Where-Object { $_ }) -join ',' }
    $copy = $kCopy.Checked -and $spd -eq 1 -and -not $kComp.Checked
    $noA = $cMode.Text -eq 'Remove audio'
    $x = Audio-Extra $ss $se $(if($cSeek.SelectedIndex -eq 0){ $ss } else { 0 }) $af $noA
    if($cMode.Text -in 'Replace with file','Mix with original' -and -not $x -and -not $noA -and -not $warnedRep){ $warnedRep = $true; M "Audio file not found - keeping the original audio." }
    $xi = if($x){ $x.Inp } else { '' }
    $a = if($cSeek.SelectedIndex -eq 0){ "$times -i `"$in`"$xi" } else { "-i `"$in`"$xi $times" }
    $tot = if($e0){ $se } else { Get-DurC $in }
    $dur = if($tot){ $tot - $ss } else { 0 }
    $est = $null
    if($copy){
      $a += $(if($af -or $x){ " -c:v copy" } else { " -c copy" }); if(($af -or $x) -and -not $noA){ $a += $(if($x){ Aud-Args $null $true } else { Aud-Args $af }) }
      if($kFix.Checked){ $a += " -avoid_negative_ts make_zero" }
      if(-not $lenCache.ContainsKey($in)){
        $fd = Get-Dur $in; $fl = (Get-Item -LiteralPath $in -ErrorAction SilentlyContinue).Length
        $lenCache[$in] = if($fd -and $fl){ $fl / $fd } else { 0 }
      }
      if($lenCache[$in] -gt 0 -and $dur -gt 0){ $est = $lenCache[$in] * $dur }
    }
    else {
      $a += " -c:v $(CodecName)"
      $vf = @()
      if($spd -ne 1){ $vf += "setpts=PTS/$($spd.ToString($inv))" }
      if($kComp.Checked -and $cCScale.Text -match '^(\d+)p$'){ $vf += "scale=-2:'min($($Matches[1]),ih)'" }  # only shrinks, never upscales
      if($vf){ $a += " -vf `"$($vf -join ',')`"" }
      if($kFix.Checked){
        $a += " -g 120 -force_key_frames `"expr:gte(t,n_forced*2)`""
        if((CodecName) -like '*_amf'){ $a += " -forced_idr 1" } elseif((CodecName) -like '*_nvenc'){ $a += " -forced-idr 1" }
      }
      $cn = CodecName
      if($cn -like '*_amf'){ if($cQual.Text -and $cQual.Text -ne '(none)'){ $a += " -quality $($cQual.Text)" } }
      elseif($cn -in 'libx264','libx265' -or $cn -like '*_nvenc'){ if($cPreset.Text -and $cPreset.Text -ne '(none)'){ $a += " -preset $($cPreset.Text)" } }
      $br = $null
      if($kSrc.Checked){
        if(-not $srcCache.ContainsKey($in)){ $srcCache[$in] = Get-SrcBitrate $in }
        $br = $srcCache[$in]
        if(-not $br -and -not $warned){ $warned = $true; M "Couldn't read the source bitrate (is ffprobe in PATH?). -b:v will be left out." }
      } elseif($tBv.Text){ $br = Parse-Rate $tBv.Text }
      if($kComp.Checked){  # compress: target bitrate and/or target size, the smaller wins
        $cb = Parse-Rate $tCBit.Text; if($cb){ $br = $cb }
        $cs = 0.0
        if([double]::TryParse($tCSize.Text,'Float',$inv,[ref]$cs) -and $cs -gt 0 -and $dur -gt 0){
          $ab = Parse-Rate $tBa.Text; if(-not $ab){ $ab = 192000 }
          $sz = [long](($cs * 1e6 * 8 * 0.97) / $dur - $ab)
          if($sz -gt 0 -and (-not $br -or $sz -lt $br)){ $br = $sz }
        }
      }
      if($kLim.Checked -and $tLim.Text -and $dur -gt 0 -and -not $fsBytes){
        try {
          $ab = Parse-Rate $tBa.Text; if(-not $ab){ $ab = 192000 }
          $cap = [long](([double]$tLim.Text * 1e9 * 8 * 0.97) / $dur - $ab)  # 3% safety margin
          if(-not $br){ $br = [Math]::Min($cap, 10000000) } elseif($br -gt $cap){ $br = $cap }
        } catch {}
      }
      if($br){
        $a += " -b:v $([long]$br)"
        $ab2 = Parse-Rate $tBa.Text; if(-not $ab2 -or $cAud.Text -eq 'copy'){ $ab2 = 192000 }
        if($dur -gt 0){ $est = ($br + $ab2) * $dur / 8 }
      }
      if($tMax.Text){ $a += " -maxrate $($tMax.Text)" }
      if($tBuf.Text){ $a += " -bufsize $($tBuf.Text)" }
      if(-not $noA){ $a += $(if($x){ Aud-Args $null $true } else { Aud-Args $af }) }
    }
    if($noA){ $a += " -an" } elseif($x){ $a += " " + $x.Cmd }
    if($kStrip.Checked){ $a += " -map_metadata -1" }
    if($tTitle.Text){ $a += " -metadata title=`"$($tTitle.Text.Replace('"',"'"))`"" }
    if($tExtra.Text){ $a += " $($tExtra.Text)" }
    if($fsBytes){ $a += " -fs $fsBytes" }
    if($kFast.Checked -and $ext -in 'mp4','mov','m4v'){ $a += " -movflags +faststart" }
    if($kY.Checked){ $a += " -y" }
    $list += [pscustomobject]@{ Pre = $a; Out = $out; In = $in; Dur = $dur; Est = $est }
  }
  $script:nSkipped = 0
  if($kSkip.Checked -and -not $rowsOverride){ $n0 = $list.Count; $list = @($list | Where-Object { -not (Test-Path -LiteralPath $_.Out) }); $script:nSkipped = $n0 - $list.Count }
  ,$list
}

$bPrev.Add_Click({
  $kEdit.Checked = $false
  if($kExact.Checked){
    $gb = 0.0; try { $gb = [double]$tLim.Text } catch {}
    if(-not $script:files.Count){ M "Choose or drop a video first."; return }
    if($gb -le 0){ M "Enter a size limit in GB (like 1.9)."; return }
    Set-Box ((Exact-Preview ([long]($gb * 1e9))) -join "`r`n`r`n"); return
  }
  $cmds = Build-Commands
  $head = @()
  if(-not (Table-Rows).Count -and $cmds.Count){ $head += "# The table is empty, so this converts the entire video (blank start and end = whole video)." }
  if(-not $cmds.Count -and -not $script:nSkipped){  # no video either: show a sample
    $row = [pscustomobject]@{ IsNewRow = $false; Cells = @([pscustomobject]@{ Value = '' }, [pscustomobject]@{ Value = '' }, [pscustomobject]@{ Value = 'sample' }, [pscustomobject]@{ Value = 'input.mp4' }) }
    $cmds = Build-Commands @($row)
    $head += "# No video chosen, so this is a sample for the whole of input.mp4."
  }
  if($script:nSkipped){ $head += "# $($script:nSkipped) existing file(s) will be skipped" }
  if($kWait.Checked){ $head += "# Run also adds: -progress <temp file> -nostats (only for the progress bar)" }
  Set-Box (($head + @($cmds | ForEach-Object { Preview-Line "$($_.Pre)" $_.Out $_.Est $kWait.Checked })) -join "`r`n`r`n")
})

# ---- Run (with progress + cancel) ----
$bCancel.Add_Click({ $script:cancel = $true; $status.Text = "Cancelling..." })
$bRun.Add_Click({
  if($kEdit.Checked){ Run-Edited; return }
  if($kExact.Checked){ Run-Exact; return }
  $cmds = Build-Commands
  if(-not $cmds.Count){ M $(if($script:nSkipped){ "All outputs already exist, so everything would be skipped." } else { "Choose a video first (an empty table converts the entire video), or add rows." }); return }
  foreach($c in $cmds){ if(-not (Test-Path -LiteralPath $c.In)){ M "Input file not found:`n$($c.In)"; return }; if($c.Out -eq $c.In){ M "Output would overwrite the input:`n$($c.In)`nUse a different output folder or format."; return } }
  $tot = 0; $max = 0; $unk = 0; $big = 0
  foreach($c in $cmds){
    if($c.Est){ $tot += $c.Est; $max = [math]::Max($max, $c.Est); if($kLim.Checked -and $tLim.Text -and $c.Est -gt [double]$tLim.Text * 1e9){ $big++ } } else { $unk++ }
  }
  $msg = "This will create $($cmds.Count) file(s) in:`n$(if($tOut.Text){ $tOut.Text } else { '(current folder)' })`n`n"
  if($tot -gt 0){ $msg += "Estimated total size: ~$(GB $tot)`nLargest file: ~$(GB $max)`n" }
  if($unk){ $msg += "$unk file(s) can't be estimated (-b:v is empty).`n" }
  if($script:nSkipped){ $msg += "$($script:nSkipped) existing file(s) will be skipped.`n" }
  if($big){ $msg += "`nWarning: $big file(s) may be over $($tLim.Text) GB.`n" }
  if($kY.Checked){ $msg += "`nFiles with the same name will be overwritten." }
  if([Windows.Forms.MessageBox]::Show("$msg`n`nStart?","Confirm",'YesNo','Question') -ne 'Yes'){ return }
  $script:cancel = $false; $bRun.Enabled = $false; $bCancel.Enabled = $true; $pb.Value = 0
  $tmp = Join-Path $env:TEMP "ffsplit_progress.txt"; $n = 0; $skipped = $script:nSkipped
  foreach($c in $cmds){
    if($script:cancel){ break }
    $n++
    $status.Text = "Running $n of $($cmds.Count): $(Split-Path $c.Out -Leaf)"
    $p = @{ FilePath = 'ffmpeg'; PassThru = $true }
    if(-not $kVis.Checked){ $p.WindowStyle = 'Hidden' }
    if($kWait.Checked){
      Remove-Item $tmp -ErrorAction SilentlyContinue
      $p.ArgumentList = "$($c.Pre) -progress `"$tmp`" -nostats `"$($c.Out)`""
      $proc = Start-Process @p
      while(-not $proc.HasExited){
        Start-Sleep -Milliseconds 300; [Windows.Forms.Application]::DoEvents()
        if($script:cancel){ try { $proc.Kill() } catch {}; break }
        try {
          $t = Get-Content $tmp -ErrorAction Stop | Select-String 'out_time_us=(\d+)' | Select-Object -Last 1
          if($t -and $c.Dur -gt 0){ $fr = [math]::Min(1, ([double]$t.Matches[0].Groups[1].Value / 1e6) / $c.Dur); $pb.Value = [int](100 * (($n-1) + $fr) / $cmds.Count) }
        } catch {}
      }
      if(-not $script:cancel){ $status.Text = "$check $n of $($cmds.Count) done: $(Split-Path $c.Out -Leaf)" }
    } else {
      $p.ArgumentList = "$($c.Pre) `"$($c.Out)`""
      [void](Start-Process @p)
    }
  }
  $bRun.Enabled = $true; $bCancel.Enabled = $false
  if($script:cancel){ $pb.Value = 0; $status.Text = "Cancelled. The last file may be incomplete - delete it."; return }
  if($kWait.Checked){ Finish "Finished encoding all videos: $n file(s)$(if($skipped){ ", $skipped skipped" })." } else { $status.Text = "Started $n job(s) in separate windows." }
  if($kOpen.Checked -and $kWait.Checked){
    $dir = if($tOut.Text -and (Test-Path $tOut.Text)){ $tOut.Text } else { Split-Path $cmds[0].Out }
    if($dir){ Start-Process explorer.exe $dir }
  }
})

# ---- Split at exact size: each part stops at the size limit, next part starts where it ended ----
function Run-Exact {
  if(-not $script:files.Count){ M "Choose or drop a video first."; return }
  $gb = 0.0; try { $gb = [double]$tLim.Text } catch {}
  if($gb -le 0){ M "Enter a size limit in GB (like 1.9)."; return }
  $bytes = [long]($gb * 1e9); $inv = [Globalization.CultureInfo]::InvariantCulture
  $tmp = Join-Path $env:TEMP "ffsplit_progress.txt"
  $lines = @(); $sumParts = 0
  foreach($file in $script:files){
    $x = Exact-Info $file $bytes
    if($x.Est){ $sumParts += $x.Parts; $lines += "- $(Split-Path $file -Leaf): ~$($x.Parts) file(s), source ~$(GB $x.Est), last file ~$(GB ($x.Est - ($x.Parts-1)*$bytes))" }
    else { $lines += "- $(Split-Path $file -Leaf): can't estimate (tick source bitrate or fill -b:v)" }
  }
  $msg = "Each file stops at about $gb GB (a few MB over is normal).`nThe commands are in Preview. Later parts start where the previous one ended.`n`n" + ($lines -join "`n")
  if($sumParts){ $msg += "`n`nEstimated total: ~$sumParts file(s)" + $(if($kCopy.Checked){ "" } else { " (re-encode estimate, may vary)" }) }
  $msg += "`nOutput: $(if($tOut.Text){ $tOut.Text } else { '(current folder)' })"
  if($kY.Checked){ $msg += "`nFiles with the same name will be overwritten." }
  if([Windows.Forms.MessageBox]::Show("$msg`n`nStart?","Confirm",'YesNo','Question') -ne 'Yes'){ return }
  $script:cancel = $false; $bRun.Enabled = $false; $bCancel.Enabled = $true; $pb.Value = 0
  $i = 1; $made = 0; $last = $null
  foreach($file in $script:files){
    $total = Get-Dur $file
    if(-not $total){ M "Couldn't read the length of $(Split-Path $file -Leaf). Is ffprobe in PATH?"; continue }
    $start = 0.0; $guard = 0
    while($start -lt $total - 1 -and -not $script:cancel -and $guard -lt 200){
      $guard++
      $row = [pscustomobject]@{ IsNewRow = $false; Cells = @(
        [pscustomobject]@{ Value = $start.ToString('0.###',$inv) }, [pscustomobject]@{ Value = $total.ToString('0.###',$inv) },
        [pscustomobject]@{ Value = (Row-Name $file $i 'min') }, [pscustomobject]@{ Value = $file }) }
      $c = (Build-Commands @($row) $bytes)[0]
      $last = $c.Out
      $status.Text = "Part $i from $(TS $start) of $(Split-Path $file -Leaf)..."
      if(-not ($kSkip.Checked -and (Test-Path -LiteralPath $c.Out))){
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p = @{ FilePath = 'ffmpeg'; PassThru = $true; ArgumentList = "$($c.Pre) -progress `"$tmp`" -nostats `"$($c.Out)`"" }
        if(-not $kVis.Checked){ $p.WindowStyle = 'Hidden' }
        $proc = Start-Process @p
        while(-not $proc.HasExited){
          Start-Sleep -Milliseconds 300; [Windows.Forms.Application]::DoEvents()
          if($script:cancel){ try { $proc.Kill() } catch {}; break }
          try {
            $t = Get-Content $tmp -ErrorAction Stop | Select-String 'out_time_us=(\d+)' | Select-Object -Last 1
            if($t){ $pb.Value = [int][math]::Min(100, 100 * ($start + [double]$t.Matches[0].Groups[1].Value / 1e6) / $total) }
          } catch {}
        }
      }
      if($script:cancel){ break }
      $d = Get-Dur $c.Out
      if(-not $d -or $d -lt 1){ M "Part $i came out empty or its length couldn't be read. Stopping."; break }
      $start += $d; $i++; $made++
    }
  }
  $bRun.Enabled = $true; $bCancel.Enabled = $false
  if($script:cancel){ $pb.Value = 0; $status.Text = "Cancelled. The last file may be incomplete - delete it."; return }
  Finish "Finished encoding all videos: $made file(s) cut at about $gb GB each."
  if($kOpen.Checked){
    $dir = if($tOut.Text -and (Test-Path $tOut.Text)){ $tOut.Text } elseif($last){ Split-Path $last }
    if($dir){ Start-Process explorer.exe $dir }
  }
}

# ---- Audio window: three tabs (controls are built on tab pages by pointing $f at them, then $f is restored) ----
function NUD($x,$y,$w,$min,$max,$val){ $n = New-Object Windows.Forms.NumericUpDown; $n.Location = "$x,$y"; $n.Width = $w; $n.DecimalPlaces = 1; $n.Increment = [decimal]0.5; $n.Minimum = $min; $n.Maximum = $max; $n.Value = $val; $f.Controls.Add($n); $n }
$main = $f; $dlg = New-Object Windows.Forms.Form
$dlg.Text = "Audio"; $dlg.Size = '585,700'; $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false
$tc = New-Object Windows.Forms.TabControl; $tc.Location = '5,5'; $tc.Size = '565,610'; $dlg.Controls.Add($tc)
$tpE = New-Object Windows.Forms.TabPage; $tpE.Text = 'Edit audio'; [void]$tc.TabPages.Add($tpE)
$tpX = New-Object Windows.Forms.TabPage; $tpX.Text = 'Extract and Combine'; [void]$tc.TabPages.Add($tpX)
$tpB = New-Object Windows.Forms.TabPage; $tpB.Text = 'BPM changer'; [void]$tc.TabPages.Add($tpB)

$f = $tpE
L "Volume" 15 18; $tVol = T "0" 110 15 60; LG "(+6 or -6 dB, or 1.5x)" 180 18
$kNoise = K "Reduce background noise" $false 360 16
L "Mute ranges" 15 52; $tMute = T "" 110 49 410; LG "Video time, e.g. 00:01:00-00:01:30, 00:05:00-00:05:10" 110 75
L "Add audio at  (Audio 1, Audio 2, ... each with its own file)" 15 108
$gIns = New-Object Windows.Forms.DataGridView; $gIns.Location = '15,130'; $gIns.Size = '505,130'; $gIns.AllowUserToAddRows = $true; $gIns.RowHeadersWidth = 70; $gIns.AutoSizeColumnsMode = 'Fill'
[void]$gIns.Columns.Add('r','Range (start-end)'); [void]$gIns.Columns.Add('f','Audio file')
$cm = New-Object Windows.Forms.DataGridViewComboBoxColumn; $cm.Name = 'm'; $cm.HeaderText = 'Mode'; [void]$cm.Items.Add('Mix with original'); [void]$cm.Items.Add('Mute original'); [void]$gIns.Columns.Add($cm)
[void]$gIns.Columns.Add('v','Volume'); $gIns.Columns[0].FillWeight = 28; $gIns.Columns[1].FillWeight = 40; $gIns.Columns[2].FillWeight = 22; $gIns.Columns[3].FillWeight = 10
$f.Controls.Add($gIns)
$bInsAdd = B "Add audio files..." 15 265 150; $bInsDel = B "Remove row" 170 265 110
LG "Range like 00:01:00-00:01:30.  Mix = keep the original sound too.  Mute = silence the original in that range." 15 295
LG "Double-click a File cell to browse, or drag audio files onto the table. Audio mode below is ignored while rows exist." 15 313
L "Audio mode" 15 350; $cMode = C @('Keep original','Replace with file','Mix with original','Remove audio') 'Keep original' 110 347 170
$cMode.DropDownStyle = 'DropDownList'; $cMode.SelectedIndex = 0
L "Audio file" 15 385; $tRep = T "" 110 382 300; $bRep = B "Browse" 420 380 100
L "Use from" 15 420; $tRs = T "" 110 417 80; L "to" 200 420; $tRe = T "" 225 417 80; $bPlay = B "Play preview" 420 415 100
LG "Blank = the whole file. If the video is shorter, the audio stops with it." 110 445
L "File volume" 15 475; $tAddVol = T "0" 110 472 60; LG "(dB or 1.5x)" 180 475
$kLoopA = K "Loop the file if it is shorter than the video" $false 280 473

$f = $tpX
L "---  Extract / convert audio  (Combine below also uses this format and folder)  ---" 15 15
L "Format" 15 43; $cFmt = C @('mp3','m4a','aac','wav','flac','opus','ogg') 'mp3' 70 40 80
$cFmt.DropDownStyle = 'DropDownList'; $cFmt.SelectedIndex = 0
L "Output folder" 165 43; $tAOut = T "" 255 40 175; $bAOut = B "Browse" 440 38 90
L "Start" 15 80; $tAs = T "" 60 77 80; L "End" 155 80; $tAe = T "" 190 77 80; LG "(blank = the whole file)" 280 80
$bExtract = B "Extract / convert" 400 74 130
LG "Audio-only input files: Run converts them to this format and ignores the video options." 15 108
L "---  Combine audio files  ---" 15 140
$bCmbPick = B "Add audio files..." 15 162 140; $bCmbUp = B "Move up" 160 162 80; $bCmbDown = B "Move down" 245 162 90; $bCmbDel = B "Remove" 340 162 80; $bCmbClr = B "Clear" 425 162 70
$lbCmb = New-Object Windows.Forms.ListBox; $lbCmb.Location = '15,192'; $lbCmb.Size = '505,110'; $f.Controls.Add($lbCmb)
LG "The list order is the combine order (1 first). Select a file, then Move up / Move down." 15 307
L "Mode" 15 337; $cCmb = C @('Join one after another','Mix together') 'Join one after another' 60 334 190
$cCmb.DropDownStyle = 'DropDownList'; $cCmb.SelectedIndex = 0
L "Name" 265 337; $tCmbName = T "combined" 310 334 110; $bCombine = B "Combine" 435 332 85

$f = $tpB
L "1.  Audio file  (or drag and drop it onto this tab)" 15 15
$tBpmIn = T "" 15 40 405; $tBpmIn.ReadOnly = $true; $bBpmBrowse = B "Browse..." 430 38 90
L "2.  Original BPM" 15 80
$nOrig = NUD 15 105 90 20 300 100
$bBpmDet = B "Detect BPM" 115 103 100; $bBpmHalf = B "/ 2" 220 103 45; $bBpmDbl = B "x 2" 270 103 45; $bBpmTap = B "Tap tempo" 320 103 100
$lBpmDet = New-Object Windows.Forms.Label; $lBpmDet.Text = "Detected BPM will appear here."; $lBpmDet.Location = '15,138'; $lBpmDet.AutoSize = $true; $lBpmDet.ForeColor = 'Gray'; $f.Controls.Add($lBpmDet)
L "3.  Target BPM" 15 175
$nTgt = NUD 15 200 90 20 400 110
$lBpmSpd = New-Object Windows.Forms.Label; $lBpmSpd.Location = '115,204'; $lBpmSpd.AutoSize = $true; $f.Controls.Add($lBpmSpd)
$kBpmSplit = K "Also save separate vocal + instrumental files (needs Demucs)" $false 15 245
LG "Demucs is an AI tool: install Python, then run  pip install demucs. A few minutes per song on a CPU." 15 270
LG "Saved in the output folder of the Extract tab, in the input's format, as name_110bpm.mp3. Pitch stays the same (ffmpeg atempo)." 15 300
$bBpm = B "Change BPM" 15 335 505 40
L "Output" 15 385
$tBpmOut = New-Object Windows.Forms.TextBox; $tBpmOut.Multiline = $true; $tBpmOut.ReadOnly = $true; $tBpmOut.ScrollBars = 'Both'; $tBpmOut.WordWrap = $false; $tBpmOut.Font = 'Consolas,9'; $tBpmOut.Location = '15,408'; $tBpmOut.Size = '505,125'; $f.Controls.Add($tBpmOut)
$bBpmOpen = B "Open output folder" 15 540 160; $bBpmClear = B "Clear output" 180 540 110

$f = $dlg; $bOk = B "Close" 465 625 100; $bOk.DialogResult = 'OK'; $f.AcceptButton = $bOk
$f = $main
$dlg = $dlg
$bAudio.Add_Click({ [void]$dlg.ShowDialog($f) })
function Audio-Dir {  # Extract folder, else the main output folder, else next to the first file we know about
  if($tAOut.Text){ $tAOut.Text } elseif($tOut.Text){ $tOut.Text }
  elseif($script:files.Count){ Split-Path $script:files[0] } elseif($script:bpmFile){ Split-Path $script:bpmFile } elseif($script:cmb.Count){ Split-Path $script:cmb[0] } else { [Environment]::GetFolderPath('MyMusic') }
}
# --- Add audio at: table helpers ---
function Number-Ins { $i = 0; foreach($r in $gIns.Rows){ $i++; $r.HeaderCell.Value = "Audio $i" } }
$gIns.Add_RowsAdded({ Number-Ins }); $gIns.Add_RowsRemoved({ Number-Ins })
$bInsAdd.Add_Click({ $d = New-Object Windows.Forms.OpenFileDialog; $d.Multiselect = $true; $d.Filter = "Audio|*.mp3;*.m4a;*.aac;*.wav;*.flac;*.opus;*.ogg|All|*.*"; if($d.ShowDialog() -eq 'OK'){ foreach($x in $d.FileNames){ [void]$gIns.Rows.Add('', $x, 'Mix with original', '') } } })
$bInsDel.Add_Click({
  $rows = @(); foreach($r in $gIns.SelectedRows){ if(-not $r.IsNewRow){ $rows += $r } }
  foreach($c in $gIns.SelectedCells){ $r = $gIns.Rows[$c.RowIndex]; if(-not $r.IsNewRow -and $rows -notcontains $r){ $rows += $r } }
  foreach($r in $rows){ $gIns.Rows.Remove($r) }
})
$gIns.Add_CellDoubleClick({ if($_.ColumnIndex -eq 1 -and $_.RowIndex -ge 0){ $d = New-Object Windows.Forms.OpenFileDialog; $d.Filter = "Audio|*.mp3;*.m4a;*.aac;*.wav;*.flac;*.opus;*.ogg|All|*.*"; if($d.ShowDialog() -eq 'OK'){ $gIns.Rows[$_.RowIndex].Cells[1].Value = $d.FileName } } })
$gIns.AllowDrop = $true; $gIns.Add_DragEnter($enter); $gIns.Add_DragDrop({ $p = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if($p){ foreach($x in $p){ [void]$gIns.Rows.Add('', $x, 'Mix with original', '') } } })

# --- BPM changer (ported from BPM Changer v1.1.0); everything it does is written to its Output box ---
function Bpm-Log($t){ $tBpmOut.AppendText("$t`r`n"); [Windows.Forms.Application]::DoEvents() }
function Bpm-Step($exe,$a){  # one hidden process, window kept alive; logs the command and what it printed; $true on success
  Bpm-Log "> $exe $a"
  $p = @{ FilePath = $exe; ArgumentList = $a; PassThru = $true; WindowStyle = 'Hidden'; RedirectStandardError = $ffLog }
  $pr = Start-Process @p; Wait-Ffmpeg $pr $null 0 0 0; $pr.WaitForExit()
  $tail = if(Test-Path $ffLog){ (@(Get-Content $ffLog -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) | Select-Object -Last 8) -join "`r`n" }
  if($tail){ Bpm-Log $tail }
  if($pr.ExitCode -eq 0){ Bpm-Log "OK"; $true } else { Bpm-Log "FAILED (exit code $($pr.ExitCode))"; $false }
}
function Atempo-Chain([double]$t){  # older ffmpeg builds only accept 0.5-2.0 per atempo, so chain if needed
  $parts = @(); while($t -gt 2.0){ $parts += 'atempo=2.0'; $t = $t / 2.0 }; while($t -lt 0.5){ $parts += 'atempo=0.5'; $t = $t / 0.5 }
  $parts += ('atempo=' + $t.ToString('0.######',$inv)); $parts -join ','
}
function Num-Set($n,[decimal]$v){ if($v -lt $n.Minimum){ $v = $n.Minimum }; if($v -gt $n.Maximum){ $v = $n.Maximum }; $n.Value = $v }
function Bpm-Speed { $r = [double]$nTgt.Value / [double]$nOrig.Value; $pct = ($r - 1) * 100; $lBpmSpd.Text = ('Speed x{0:0.000}  ({1}{2:0.0}%)  -  pitch stays the same' -f $r, $(if($pct -ge 0){ '+' } else { '' }), $pct) }
function Bpm-Detect {
  if(-not $script:bpmFile){ Bpm-Log "Choose an audio file first."; return }
  $raw = Join-Path $env:TEMP ("bpmchanger_" + [guid]::NewGuid() + ".raw"); $script:cancel = $false
  Bpm-Log "Analyzing the tempo of $(Split-Path $script:bpmFile -Leaf) (first 2 minutes)..."
  if(-not (Bpm-Step 'ffmpeg' ('-v error -y -i "{0}" -t 120 -vn -ac 1 -ar 11025 -f s16le "{1}"' -f $script:bpmFile, $raw))){ $lBpmDet.Text = "Could not read this audio file."; return }
  $bpm = [BpmDetector]::Detect($raw, 11025); Remove-Item -LiteralPath $raw -ErrorAction SilentlyContinue
  if($bpm -le 0){ $lBpmDet.Text = "Could not detect the BPM (file too short?). Type it or tap it."; Bpm-Log $lBpmDet.Text; return }
  Num-Set $nOrig ([decimal]$bpm); Num-Set $nTgt ([decimal][math]::Round($bpm + 10))
  $alts = @(); if($bpm / 2 -ge 50){ $alts += ('{0:0.#}' -f ($bpm / 2)) }; if($bpm * 2 -le 220){ $alts += ('{0:0.#}' -f ($bpm * 2)) }
  $lBpmDet.Text = ('Detected: {0:0.0} BPM   (could also be {1} - tap along to check)' -f $bpm, ($alts -join ' or ')); Bpm-Log $lBpmDet.Text
  Bpm-Log "Set the target BPM and press Change BPM."
}
function Bpm-Set($path){ if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return }; $script:bpmFile = $path; $tBpmIn.Text = $path; $lBpmDet.Text = ''; Bpm-Log "File: $path"; Bpm-Detect }
function Find-Demucs {
  $d = Get-Command demucs -ErrorAction SilentlyContinue; if($d){ return @{ File = $d.Source; Prefix = '' } }
  foreach($py in 'python','py'){ $c = Get-Command $py -ErrorAction SilentlyContinue
    if($c){ $pr = Start-Process $c.Source -ArgumentList '-c "import demucs"' -WindowStyle Hidden -PassThru -Wait; if($pr.ExitCode -eq 0){ return @{ File = $c.Source; Prefix = '-m demucs ' } } } }
  $null
}
function Bpm-Split($out,$filter,$x){  # vocals + instrumental with Demucs, same tempo change on each; returns the saved paths or $null
  $dm = Find-Demucs; if(-not $dm){ Bpm-Log "Demucs was not found. Install Python, then run: pip install demucs"; return $null }
  $tmp = Join-Path $env:TEMP ('bpmchanger_' + [guid]::NewGuid().ToString('N')); [void](New-Item -ItemType Directory $tmp)
  try {
    $wav = Join-Path $tmp 'track.wav'; Bpm-Log 'Splitting: preparing audio...'
    if(-not (Bpm-Step 'ffmpeg' ('-v error -y -i "{0}" -vn -ac 2 -ar 44100 "{1}"' -f $script:bpmFile, $wav))){ return $null }
    Bpm-Log 'Splitting vocals / instrumental with Demucs... (a few minutes on a CPU)'; $stems = Join-Path $tmp 'stems'
    if(-not (Bpm-Step $dm.File ('{0}--two-stems=vocals -o "{1}" "{2}"' -f $dm.Prefix, $stems, $wav))){ return $null }
    $voc = Get-ChildItem $stems -Recurse -Filter 'vocals.wav' -ErrorAction SilentlyContinue | Select-Object -First 1
    $ins = Get-ChildItem $stems -Recurse -Filter 'no_vocals.wav' -ErrorAction SilentlyContinue | Select-Object -First 1
    if(-not $voc -or -not $ins){ Bpm-Log "Demucs did not produce the stems."; return $null }
    $dir = Split-Path $out -Parent; $b = [IO.Path]::GetFileNameWithoutExtension($out); $ext = [IO.Path]::GetExtension($out); $made = @()
    foreach($j in @(@($voc.FullName, "${b}_vocals$ext", 'vocals'), @($ins.FullName, "${b}_instrumental$ext", 'instrumental'))){
      $dest = Join-Path $dir $j[1]; Bpm-Log "Changing tempo of the $($j[2]) track..."
      if(-not (Bpm-Step 'ffmpeg' ('-y -i "{0}" -filter:a "{1}" {2}"{3}"' -f $j[0], $filter, $x, $dest))){ return $null }
      $made += $dest
    }
    return $made
  } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
function Bpm-Convert {
  if(-not $script:bpmFile){ Bpm-Log "Choose an audio file first."; return }
  $dir = Audio-Dir; if(-not (Test-Path $dir)){ [void](New-Item -ItemType Directory -Force $dir) }
  $b = [IO.Path]::GetFileNameWithoutExtension($script:bpmFile); $ext = [IO.Path]::GetExtension($script:bpmFile)
  $out = Join-Path $dir ("{0}_{1}bpm{2}" -f $b, ([decimal]$nTgt.Value).ToString('0.##',$inv), $ext)
  if($out -eq $script:bpmFile){ Bpm-Log "The output would overwrite the input. Pick another Output folder on the Extract and Combine tab."; return }
  $filter = Atempo-Chain ([double]$nTgt.Value / [double]$nOrig.Value); $x = if($ext -ieq '.mp3'){ '-q:a 0 ' } else { '' }
  $script:cancel = $false; $script:bpmOut = $out
  Bpm-Log ("Changing {0:0.#} -> {1:0.#} BPM" -f $nOrig.Value, $nTgt.Value); Bpm-Log "Output file: $out"
  if(-not (Bpm-Step 'ffmpeg' ('-y -i "{0}" -filter:a "{1}" {2}"{3}"' -f $script:bpmFile, $filter, $x, $out))){ return }
  $saved = @($out)
  if($kBpmSplit.Checked){ $st = Bpm-Split $out $filter $x; if(-not $st){ Bpm-Log "The BPM file was saved, but splitting failed."; return }; $saved += $st }
  foreach($sv in $saved){ Bpm-Log ("Saved: {0}  ({1:0.0} MB)" -f $sv, ((Get-Item -LiteralPath $sv).Length / 1MB)) }
  Finish ("BPM changed. Saved: " + (($saved | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
}
$bBpmBrowse.Add_Click({ try { $d = New-Object Windows.Forms.OpenFileDialog; $d.Filter = "Audio|*.mp3;*.wav;*.flac;*.m4a;*.aac;*.ogg;*.opus;*.wma|All|*.*"; if($d.ShowDialog() -eq 'OK'){ Bpm-Set $d.FileName } } catch { Bpm-Log ("ERROR: " + $_.Exception.Message) } })
$bBpmDet.Add_Click({ try { Bpm-Detect } catch { Bpm-Log ("ERROR: " + $_.Exception.Message) } })
$bBpmHalf.Add_Click({ Num-Set $nOrig ($nOrig.Value / 2) }); $bBpmDbl.Add_Click({ Num-Set $nOrig ($nOrig.Value * 2) })
$bBpmTap.Add_Click({  # tap along to the music; 4+ taps; a pause over 2 s restarts the count
  $now = $script:clock.Elapsed.TotalSeconds; $n = $script:tap.Count
  if($n -gt 0 -and ($now - $script:tap[$n - 1]) -gt 2.0){ $script:tap.Clear() }
  $script:tap.Add($now); if($script:tap.Count -gt 12){ $script:tap.RemoveAt(0) }; $n = $script:tap.Count
  if($n -ge 4){ $bpm = 60.0 * ($n - 1) / ($script:tap[$n - 1] - $script:tap[0]); Num-Set $nOrig ([decimal][math]::Round($bpm,1)); $lBpmDet.Text = ('Tapped: {0:0.0} BPM   ({1} taps - keep going for more accuracy)' -f $bpm, $n) }
  else { $lBpmDet.Text = ('Keep tapping to the beat... ({0}/4)' -f $n) }
})
$nOrig.Add_ValueChanged({ Bpm-Speed }); $nTgt.Add_ValueChanged({ Bpm-Speed })
$bBpm.Add_Click({ try { Bpm-Convert } catch { Bpm-Log ("ERROR: " + $_.Exception.Message) } })
$bBpmOpen.Add_Click({ $a = if($script:bpmOut -and (Test-Path -LiteralPath $script:bpmOut)){ "/select,`"$($script:bpmOut)`"" } else { "`"$(Audio-Dir)`"" }; Start-Process explorer.exe -ArgumentList $a })
$bBpmClear.Add_Click({ $tBpmOut.Clear() })
$tpB.AllowDrop = $true; $tpB.Add_DragEnter($enter); $tpB.Add_DragDrop({ try { $p = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if($p){ Bpm-Set $p[0] } } catch { Bpm-Log ("ERROR: " + $_.Exception.Message) } })
Bpm-Speed

$bRep.Add_Click({ $d = New-Object Windows.Forms.OpenFileDialog; $d.Filter = "Audio|*.mp3;*.m4a;*.aac;*.wav;*.flac;*.opus;*.ogg|All|*.*"; if($d.ShowDialog() -eq 'OK'){ $tRep.Text = $d.FileName; if($cMode.SelectedIndex -eq 0){ $cMode.SelectedIndex = 1 } } })
$bAOut.Add_Click({ $d = New-Object Windows.Forms.FolderBrowserDialog; if($d.ShowDialog() -eq 'OK'){ $tAOut.Text = $d.SelectedPath } })
$bPlay.Add_Click({  # hear the chosen part of the audio file (ffplay comes with ffmpeg)
  if(-not $tRep.Text -or -not (Test-Path -LiteralPath $tRep.Text)){ M "Choose an audio file first."; return }
  $a = "-nodisp -autoexit"; if($tRs.Text){ $a += " -ss $($tRs.Text)" }
  if($tRe.Text){ $d = (Sec $tRe.Text) - $(if($tRs.Text){ Sec $tRs.Text } else { 0 }); if($d -gt 0){ $a += " -t $($d.ToString($inv))" } }
  $vf = Vol-Filter $tAddVol.Text; if($vf){ $a += " -af $vf" }
  try { Start-Process ffplay -ArgumentList "$a `"$($tRep.Text)`"" } catch { M "ffplay not found. It comes in the same folder as ffmpeg." }
})
function Show-Cmb { $lbCmb.Items.Clear(); $i = 0; foreach($x in $script:cmb){ $i++; [void]$lbCmb.Items.Add("$i. " + (Split-Path $x -Leaf)) } }
$bCmbPick.Add_Click({ $d = New-Object Windows.Forms.OpenFileDialog; $d.Multiselect = $true; $d.Filter = "Audio|*.mp3;*.m4a;*.aac;*.wav;*.flac;*.opus;*.ogg|All|*.*"; if($d.ShowDialog() -eq 'OK'){ foreach($x in $d.FileNames){ [void]$script:cmb.Add($x) }; Show-Cmb } })
$bCmbUp.Add_Click({ $k = $lbCmb.SelectedIndex; if($k -gt 0){ $t = $script:cmb[$k-1]; $script:cmb[$k-1] = $script:cmb[$k]; $script:cmb[$k] = $t; Show-Cmb; $lbCmb.SelectedIndex = $k-1 } })
$bCmbDown.Add_Click({ $k = $lbCmb.SelectedIndex; if($k -ge 0 -and $k -lt $script:cmb.Count-1){ $t = $script:cmb[$k+1]; $script:cmb[$k+1] = $script:cmb[$k]; $script:cmb[$k] = $t; Show-Cmb; $lbCmb.SelectedIndex = $k+1 } })
$bCmbDel.Add_Click({ $k = $lbCmb.SelectedIndex; if($k -ge 0){ $script:cmb.RemoveAt($k); Show-Cmb; if($script:cmb.Count){ $lbCmb.SelectedIndex = [math]::Min($k, $script:cmb.Count-1) } } })
$bCmbClr.Add_Click({ $script:cmb.Clear(); Show-Cmb })
$bCombine.Add_Click({
  if($script:cmb.Count -lt 2){ M "Choose 2 or more audio files first (button, or drag them onto the box)."; return }
  $ext = $cFmt.Text; $n = $script:cmb.Count
  $ins = ($script:cmb | ForEach-Object { "-i `"$_`"" }) -join ' '
  $labels = (0..($n-1) | ForEach-Object { "[" + $_ + ":a]" }) -join ''
  $fc = if($cCmb.SelectedIndex -eq 0){ $labels + "concat=n=$($n):v=0:a=1[aout]" } else { $labels + "amix=inputs=$($n):duration=longest:normalize=0[aout]" }
  $a = "$ins -filter_complex `"$fc`" -map `"[aout]`" -c:a $($script:audC[$ext])"
  if($ext -notin 'wav','flac' -and $tBa.Text){ $a += " -b:a $($tBa.Text)" }
  Run-Jobs "Combine audio" @([pscustomobject]@{ Args = "$a -ar 48000 -ac 2"; Out = (Join-Path (Audio-Dir) ("$($tCmbName.Text).$ext")) })
})
$bExtract.Add_Click({
  if(-not $script:files.Count){ M "Choose or drop a video first (main window)."; return }
  $ext = $cFmt.Text; $dir = Audio-Dir; $ss = if($tAs.Text){ Sec $tAs.Text } else { 0 }; $jobs = @()
  $t = (@($(if($tAs.Text){ "-ss $($tAs.Text)" }), $(if($tAe.Text){ "-to $($tAe.Text)" })) | Where-Object { $_ }) -join ' '
  foreach($file in $script:files){
    $out = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($file) + ".$ext"); if($out -eq $file){ continue }
    $se = if($tAe.Text){ Sec $tAe.Text } else { Get-DurC $file }
    $af = Audio-Filter $ss $(if($tAe.Text){ $se } else { 1e9 }) $ss
    $a = "$t -i `"$file`" -vn -c:a $($script:audC[$ext])"
    if($ext -notin 'wav','flac' -and $tBa.Text){ $a += " -b:a $($tBa.Text)" }
    $a += " -ar 48000 -ac 2"; if($af){ $a += " -af `"$af`"" }
    $jobs += [pscustomobject]@{ Args = $a; Dur = $(if($se){ $se - $ss } else { 0 }); Out = $out }
  }
  Run-Jobs "Extract audio" $jobs
})

# ---- More tools dialog ----
$main = $f; $f = New-Object Windows.Forms.Form
$f.Text = "More tools"; $f.Size = '560,470'; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false
L "Output format, Compress, GIF, Add folder and Exact size mode are on the main window." 15 18
L "Speed" 15 53; $tSpeed = T "1" 110 50 50
L "(2 = twice as fast, 0.5 = half; 0.25-4; needs re-encode)" 170 53
L "Title" 15 88; $tTitle = T "" 110 85 250; $kStrip = K "Strip all metadata" $false 380 86
$bBatch  = B "Batch convert: one row per input file" 15 125 270
$bRemux = B "Change format only (no re-encode)" 295 125 250
$bMerge  = B "Merge input files in order" 15 165 270
L "Frame times" 15 208; $tFrames = T "" 110 205 300
$bFrames = B "Extract frames (empty = thumbnail at 10%)" 15 235 270
$bAnalyze = B "Analyze first input video" 15 350 270
L "Quick shot at" 15 285; $tShot = T "" 110 282 90
$bShot = B "Show frame" 215 280 130
L "Times: hh:mm:ss (or plain seconds). Empty = selected row start, or 10% in." 15 312
L "Frames folder" 15 383; $tFrameOut = T "" 110 380 300; $bFrameOut = B "Browse" 420 378 90
$bOk2 = B "Close" 440 425 100; $bOk2.DialogResult = 'OK'; $f.AcceptButton = $bOk2
$dlg2 = $f; $f = $main
$bTools.Add_Click({ [void]$dlg2.ShowDialog($f) })
$outDir = { if($tOut.Text){ $tOut.Text } elseif($script:files.Count){ Split-Path $script:files[0] } }
$needFiles = { if(-not $script:files.Count){ M "Choose or drop a video first (main window)."; $false } else { $true } }

$bBatch.Add_Click({ $dlg2.DialogResult = 'OK'; Add-Segments 'whole'; $status.Text += " Use Run to convert them." })
$bFolder.Add_Click({
  $d = New-Object Windows.Forms.FolderBrowserDialog
  if($d.ShowDialog() -eq 'OK'){
    $v = Get-ChildItem -LiteralPath $d.SelectedPath -File | Where-Object { $_.Extension -in '.mp4','.mkv','.mov','.avi','.ts','.webm','.flv','.wmv','.m4v','.mts' } | Sort-Object Name | ForEach-Object FullName
    if($v){ Set-Files $v; $status.Text = "Added $(@($v).Count) video(s). Use Batch convert or Generate." } else { M "No video files found in that folder." }
  }
})
$bRemux.Add_Click({  # e.g. .ts -> .mp4 with -c copy; files already in that format, or already converted, are ignored
  if(-not (& $needFiles)){ return }
  $ext = $cExt.Text; $dir = & $outDir; $jobs = @(); $same = 0; $have = 0
  foreach($file in $script:files){
    $out = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($file) + ".$ext")
    if([IO.Path]::GetExtension($file).TrimStart('.') -ieq $ext){ $same++; continue }
    if(Test-Path -LiteralPath $out){ $have++; continue }
    $jobs += [pscustomobject]@{ Args = "-nostdin -i `"$file`" -map 0:v:0 -map 0:a? -c copy" + $(if($ext -in 'mp4','mov','m4v'){ ' -movflags +faststart' }); Dur = (Get-DurC $file); Out = $out }
  }
  if(-not $jobs.Count){ M "Nothing to convert: $same file(s) already .$ext, $have already converted."; return }
  if($same -or $have){ $status.Text = "Ignoring $same file(s) already .$ext and $have already converted." }
  Run-Jobs "Change format" $jobs
})
$bMerge.Add_Click({
  if($script:files.Count -lt 2){ M "Select 2 or more input videos (Browse with Ctrl-click, or drop several)."; return }
  $lst = Join-Path $env:TEMP "ffsplit_concat.txt"
  [IO.File]::WriteAllLines($lst, @($script:files | ForEach-Object { "file '" + $_.Replace("'","'\''") + "'" }), (New-Object Text.UTF8Encoding $false))
  $a = "-f concat -safe 0 -i `"$lst`""
  # shortcut: Copy mode needs clips with the same codec/size/fps; untick it to re-encode (uses codec, -b:v, audio codec from the main window)
  if($kCopy.Checked){ $a += " -c copy" } else { $a += " -c:v $(CodecName)" + $(if($tBv.Text){ " -b:v $($tBv.Text)" }) + " -c:a $($cAud.Text)" }
  if($kFast.Checked -and $cExt.Text -in 'mp4','mov'){ $a += " -movflags +faststart" }
  Run-Jobs "Merge" @([pscustomobject]@{ Args = $a; Out = (Join-Path (& $outDir) ("merged." + $cExt.Text)) })
})
$bFrames.Add_Click({
  if(-not (& $needFiles)){ return }
  $jobs = @(); $dir = Frame-Dir
  foreach($file in $script:files){
    $b = [IO.Path]::GetFileNameWithoutExtension($file)
    $ts = @($tFrames.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if(-not $ts){ $d = Get-Dur $file; if($d){ $ts = @(TS ($d * 0.1)) } }
    foreach($t in $ts){ $jobs += [pscustomobject]@{ Args = "-ss $t -i `"$file`" -frames:v 1 -q:v 2"; Out = (Join-Path $dir ("{0}_{1}.jpg" -f $b, ($t -replace '[:.]','-'))) } }
  }
  Run-Jobs "Frames" $jobs
})
$bAnalyze.Add_Click({
  $dlg2.DialogResult = 'OK'; if(-not (& $needFiles)){ return }
  $o = & ffprobe -v error -show_entries "format=format_name,duration,size,bit_rate:stream=index,codec_type,codec_name,width,height,r_frame_rate,bit_rate,channels,sample_rate" -of default=nw=1 "$($script:files[0])" 2>&1
  Show-Text "Analysis" ("$($script:files[0])`r`n`r`n" + ($o -join "`r`n"))  # shortcut: raw ffprobe output
})

$bFrameOut.Add_Click({ $d = New-Object Windows.Forms.FolderBrowserDialog; if($d.ShowDialog() -eq 'OK'){ $tFrameOut.Text = $d.SelectedPath } })
$bShot.Add_Click({  # does not close this window; the frame opens on top of it
  if(-not (& $needFiles)){ return }
  $r = $g.CurrentRow; $hasRow = $r -and -not $r.IsNewRow
  $file = if($hasRow -and $r.Cells[3].Value){ [string]$r.Cells[3].Value } else { $script:files[0] }
  $t = $tShot.Text.Trim()
  if(-not $t -and $hasRow -and $r.Cells[0].Value){ $t = [string]$r.Cells[0].Value }
  if(-not $t){ $d = Get-DurC $file; $t = if($d){ TS ($d * 0.1) } else { '00:00:05' } }
  Show-Shot $file $t (Frame-Dir) $dlg2
})

# ---- Compress dialog (tick "Compress" on the main window to use it) ----
$main = $f; $f = New-Object Windows.Forms.Form
$f.Text = "Compress videos"; $f.Size = '540,300'; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false
L "Tick Compress on the main window to use these. It re-encodes, so Copy mode is ignored." 15 15
L "Target bitrate" 15 52; $tCBit = T "10M" 120 49 70; L "(10M = 10 Mbps, 4M, 800k)" 200 52
L "Target size (MB)" 15 87; $tCSize = T "" 120 84 70; L "(optional, e.g. 25. The smaller of the two wins)" 200 87
L "Resolution" 15 122; $cCScale = C @('Keep original','1440p','1080p','720p','480p') 'Keep original' 120 119 130
$cCScale.DropDownStyle = 'DropDownList'; $cCScale.SelectedIndex = 0
L "Smaller size = lower bitrate and/or lower resolution. For sharing, 1080p at 4-6M looks good." 15 160
$bCOk = B "Close" 410 215 100; $bCOk.DialogResult = 'OK'; $f.AcceptButton = $bCOk
$dlgC = $f; $f = $main
$bComp.Add_Click({ [void]$dlgC.ShowDialog($f) })

# ---- GIF dialog (its own section) ----
$main = $f; $f = New-Object Windows.Forms.Form
$f.Text = "Make GIF"; $f.Size = '560,620'; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false
L "Start" 15 18; $tGs = T "00:00:00" 110 15 90
L "End" 15 53; $tGe = T "00:00:10" 110 50 90; LG "(hh:mm:ss or seconds; keep it short)" 210 53
L "FPS" 15 88; $tFps = T "15" 110 85 40; LG "(default 15)" 160 88
L "Width (px)" 15 123; $tGw = T "480" 110 120 50; LG "(default 480)" 170 123; $kGorig = K "Use original size" $false 270 121
L "Loop count" 15 158; $tGl = T "0" 110 155 40; LG "(default 0 = loop forever, -1 = play once)" 160 158
L "Compression" 15 195
$tbGc = New-Object Windows.Forms.TrackBar; $tbGc.Minimum = 0; $tbGc.Maximum = 100; $tbGc.Value = 10; $tbGc.TickFrequency = 10; $tbGc.Location = '110,188'; $tbGc.Width = 330; $f.Controls.Add($tbGc)
$lGc = New-Object Windows.Forms.Label; $lGc.Text = '10'; $lGc.Location = '450,195'; $lGc.AutoSize = $true; $f.Controls.Add($lGc)
$tbGc.Add_Scroll({ $lGc.Text = "$($tbGc.Value)" })
LG "Applies lossy LZW compression (needs gifsicle; without it, fewer colours). Default 10." 15 232
$kGtr = K "Preserve transparency" $false 15 258; LG "(transparent video to transparent GIF)" 190 261
$kGbg = K "Optimize for static background" $false 15 283; LG "(assign more colors to moving parts of the image)" 235 286
$kGfast = K "Fast (quicker, a bit grainier; untick for best quality)" $true 15 313
$kGhw = K "Decode on the graphics card (-hwaccel auto; untick if it errors)" $true 15 335
L "Name" 15 370; $tGn = T "clip" 110 367 200
$kGrows = K "Use the table rows instead (one GIF per row)" $false 15 395
LG "Uses the input video(s) from the main window; saved in the output folder." 15 425
$bMakeGif = B "Make GIF" 15 460 130; $bGifPrev = B "Preview first frame" 155 460 150; $bGifReset = B "Reset GIF" 315 460 100
$bGOk = B "Close" 440 525 90; $bGOk.DialogResult = 'OK'; $f.AcceptButton = $bGOk
$dlgG = $f; $f = $main
$bGif.Add_Click({ [void]$dlgG.ShowDialog($f) })
$bGifReset.Add_Click({
  $tGs.Text = '00:00:00'; $tGe.Text = '00:00:10'; $tFps.Text = '15'; $tGw.Text = '480'; $tGl.Text = '0'; $tGn.Text = 'clip'
  $tbGc.Value = 10; $lGc.Text = '10'; $kGorig.Checked = $false; $kGtr.Checked = $false; $kGbg.Checked = $false; $kGrows.Checked = $false; $kGfast.Checked = $true; $kGhw.Checked = $true
})
$bGifPrev.Add_Click({  # does not close this window
  if(-not (& $needFiles)){ return }
  Show-Shot $script:files[0] $(if($tGs.Text){ $tGs.Text } else { '00:00:00' }) (Frame-Dir) $dlgG
})
$bMakeGif.Add_Click({
  if($tFps.Text -notmatch '^\d+$' -or ($tGw.Text -notmatch '^\d+$' -and -not $kGorig.Checked) -or $tGl.Text -notmatch '^-?\d+$'){ M "FPS, width and loop count must be whole numbers."; return }
  $comp = $tbGc.Value
  $vf = Gif-Filter $tFps.Text $tGw.Text $kGorig.Checked $kGfast.Checked $comp $kGtr.Checked $kGbg.Checked
  $hw = if($kGhw.Checked){ "-hwaccel auto " } else { "" }; $lossy = if($comp -gt 10){ [int]($comp * 2) } else { 0 }
  $jobs = @(); $dir = & $outDir
  if($kGrows.Checked){
    foreach($r in $g.Rows){
      if($r.IsNewRow -or -not $r.Cells[0].Value -or -not $r.Cells[1].Value){ continue }
      $nm = ([string]$r.Cells[2].Value) -replace '\.(mp4|mkv|mov|avi|ts|webm|gif)$',''; if(-not $nm){ $nm = "gif$($jobs.Count+1)" }
      $jobs += [pscustomobject]@{ Args = "$($hw)-ss $($r.Cells[0].Value) -to $($r.Cells[1].Value) -i `"$(Input-Of $r)`" -vf `"$vf`" -loop $($tGl.Text)"; Dur = (Sec $r.Cells[1].Value) - (Sec $r.Cells[0].Value); Lossy = $lossy; Out = (Join-Path $dir "$nm.gif") }
    }
    if(-not $jobs.Count){ M "The table has no rows with a Start and End time."; return }
  } else {
    if(-not (& $needFiles)){ return }
    if(-not $tGe.Text){ M "Enter an End time (a GIF of a whole video would be huge)."; return }
    $ss = if($tGs.Text){ "-ss $($tGs.Text) " } else { "" }
    foreach($file in $script:files){
      $nm = if($script:files.Count -gt 1){ "$($tGn.Text)_$([IO.Path]::GetFileNameWithoutExtension($file))" } else { $tGn.Text }
      $jobs += [pscustomobject]@{ Args = "$($hw)$($ss)-to $($tGe.Text) -i `"$file`" -vf `"$vf`" -loop $($tGl.Text)"; Dur = (Sec $tGe.Text) - (Sec $tGs.Text); Lossy = $lossy; Out = (Join-Path $dir "$nm.gif") }
    }
  }
  if($kGorig.Checked -or [long]$tGw.Text -gt 800 -or @($jobs | Where-Object { $_.Dur -gt 30 }).Count){
    if([Windows.Forms.MessageBox]::Show("Original size, a width over 800 px, or a clip longer than 30 s needs a lot of memory and time, and makes a huge GIF.`n`nContinue?","Big GIF",'YesNo','Warning') -ne 'Yes'){ return }
  }
  Run-Jobs "GIF" $jobs
})

$cCodec.Add_TextChanged({ Sync-Codec }); Sync-Codec
$bReset = B "Reset all" 490 322 100
$bReset.Add_Click({
  if([Windows.Forms.MessageBox]::Show("Reset everything to the defaults? The app restarts, so the table and chosen files are cleared too.","Reset all",'YesNo','Question') -eq 'Yes'){
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""; $f.Close()
  }
})
foreach($fm in $dlg,$dlg2,$dlgC,$dlgG){ $fm.AllowDrop = $true; $fm.Add_DragEnter($enter); $fm.Add_DragDrop($drop) }  # drop videos on any window = input files
$tRep.AllowDrop = $true; $tRep.Add_DragEnter($enter); $tRep.Add_DragDrop({ $p = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if($p){ $tRep.Text = $p[0]; if($cMode.SelectedIndex -eq 0){ $cMode.SelectedIndex = 1 } } })
$lbCmb.AllowDrop = $true; $lbCmb.Add_DragEnter($enter); $lbCmb.Add_DragDrop({ $p = $_.Data.GetData([Windows.Forms.DataFormats]::FileDrop); if($p){ foreach($x in $p){ [void]$script:cmb.Add($x) }; Show-Cmb } })

# ---- Resize layout ----
$f.MinimumSize = '780,850'
foreach($c in @($tIn,$tOut,$tExtra)){ $c.Anchor = 'Top,Left,Right' }
foreach($c in @($bIn,$bOut)){ $c.Anchor = 'Top,Right' }
$g.Anchor = 'Top,Bottom,Left,Right'
foreach($c in @($bPrev,$bRun,$bCancel,$bDel,$bClr,$bUndo,$kEdit,$status)){ $c.Anchor = 'Bottom,Left' }
$pb.Anchor = 'Bottom,Left,Right'; $box.Anchor = 'Bottom,Left,Right'; $bUndoEdit.Anchor = 'Bottom,Right'; $bUndoBox.Anchor = 'Bottom,Right'

if($SelfTest){  # run: powershell -File FFmpegSplitter28.ps1 -SelfTest
  foreach($fm in $f,$dlg,$dlg2,$dlgC,$dlgG){ foreach($c in $fm.Controls){ if($c.Location.X -eq 0 -and $c.Location.Y -eq 0){ throw "control stuck at 0,0 (bad K/B/T/C call): $($c.GetType().Name) $($c.Text)" } } }
  if($kExact.Checked -or $kStrip.Checked -or $kNoise.Checked -or $kGrows.Checked){ throw "a checkbox starts ticked by mistake" }
  Set-Box "x"; $box.Text = "y"; [void]$bUndoEdit.GetType().GetMethod('OnClick','NonPublic,Instance').Invoke($bUndoEdit,@([EventArgs]::Empty)); if($box.Text -ne "x"){ throw "clear-edit self-test failed" }
  Set-Box "a"; $script:histTime = [datetime]::MinValue; $box.Text = "ab"; $script:histTime = [datetime]::MinValue; $box.Text = "abc"
  $oc = $bUndoBox.GetType().GetMethod('OnClick','NonPublic,Instance')
  [void]$oc.Invoke($bUndoBox,@([EventArgs]::Empty)); if($box.Text -ne "ab"){ throw "undo step 1 failed: $($box.Text)" }
  [void]$oc.Invoke($bUndoBox,@([EventArgs]::Empty)); if($box.Text -ne "a"){ throw "undo step 2 failed: $($box.Text)" }
  $tMute.Text = '00:00:10-00:00:20'; $tVol.Text = '6'; $kNoise.Checked = $true
  $r = Audio-Filter 5 30 5
  if($r -ne "afftdn,volume=6dB,volume=enable='between(t,5,15)':volume=0"){ throw "audio filter self-test failed: $r" }
  if((Atempo 4) -ne "atempo=2,atempo=2"){ throw "atempo self-test failed" }
  $tPre.Text = '{name}_{n}'; if((Row-Name 'C:\x\a.mp4' 3 'min') -ne 'a_3'){ throw "row-name self-test failed" }
  if((Preview-Line '-i x' "C:\Bob's.mp4" $null $false) -ne "Start-Process ffmpeg -ArgumentList '-i x `"C:\Bob''s.mp4`"'"){ throw "preview-line self-test failed" }
  $g.Rows.Clear(); $script:files = @('C:\x\a.mp4'); $kSrc.Checked = $false; $kLim.Checked = $false; $kComp.Checked = $false; $tPre.Text = ''
  $c = (Build-Commands)[0]
  if($c.Pre -match '-ss|-to ' -or $c.Out -notlike '*a_copy.mp4'){ throw "whole-video self-test failed: $($c.Pre) | $($c.Out)" }
  $kComp.Checked = $true; $tCBit.Text = '4M'; $tCSize.Text = ''; $cCScale.Text = '720p'; $cCodec.Text = 'libx264 (CPU)'; Sync-Codec; $cPreset.Text = 'slow'
  $c = (Build-Commands)[0]
  if($c.Pre -notmatch '-b:v 4000000' -or $c.Pre -notmatch "scale=-2:'min\(720,ih\)'" -or $c.Pre -notmatch '-preset slow' -or $c.Pre -match '-quality'){ throw "compress/preset self-test failed: $($c.Pre)" }
  $g1 = Gif-Filter 15 480 $false $true 10 $false $false; $g2 = Gif-Filter 15 480 $true $false 0 $true $true
  if($g1 -notmatch 'scale=480:-1' -or $g1 -notmatch 'bayer' -or $g2 -match 'scale' -or $g2 -notmatch 'reserve_transparent=1' -or $g2 -notmatch 'stats_mode=diff'){ throw "gif filter self-test failed: $g1 | $g2" }
  $tRep.Text = $PSCommandPath; $tRs.Text = '00:00:05'; $tRe.Text = ''; $kLoopA.Checked = $false; $tAddVol.Text = '0'; $gIns.Rows.Clear(); $cMode.Text = 'Replace with file'
  $x = Audio-Extra 0 100 0 '' $false
  if($x.Inp -notmatch '-ss 00:00:05' -or $x.Cmd -notmatch 'apad' -or $x.Cmd -notmatch '-shortest'){ throw "audio replace self-test failed: $($x.Inp) | $($x.Cmd)" }
  $cMode.Text = 'Mix with original'; $x = Audio-Extra 0 100 0 '' $false; if($x.Cmd -notmatch 'amix'){ throw "audio mix self-test failed" }
  $cMode.Text = 'Keep original'; [void]$gIns.Rows.Add('00:00:10-00:00:20', $PSCommandPath, 'Mute original', ''); $x = Audio-Extra 0 100 0 '' $false
  if($x.Cmd -notmatch 'adelay=10000:all=1' -or $x.Cmd -notmatch 'atrim=duration=10' -or $x.Cmd -notmatch 'between\(t,10,20\)'){ throw "audio insert self-test failed: $($x.Cmd)" }
  $gIns.Rows.Clear(); $cMode.Text = 'Keep original'; $tRep.Text = ''
  if((Vol-Filter '1.5x') -ne 'volume=1.5' -or (Vol-Filter '-3') -ne 'volume=-3dB'){ throw "volume self-test failed" }
  $l = Preview-Line '-i x' "C:\Bob's.mp4" $null $true
  if(@(Parse-Edited @($l))[0] -ne "-i x `"C:\Bob's.mp4`""){ throw "edit-parse self-test failed" }
  $tPre.Text = ''; if((Row-Name 'C:\x\files.mp4' 1 'fill') -ne 'files_copy'){ throw "copy-name self-test failed" }
  $script:cmb.Clear(); [void]$script:cmb.Add('a.mp3'); [void]$script:cmb.Add('b.mp3'); Show-Cmb; $lbCmb.SelectedIndex = 1
  [void]$bCmbUp.GetType().GetMethod('OnClick','NonPublic,Instance').Invoke($bCmbUp,@([EventArgs]::Empty))
  if($script:cmb[0] -ne 'b.mp3'){ throw "combine order self-test failed" }
  if((Atempo-Chain 1.1) -ne 'atempo=1.1' -or (Atempo-Chain 4) -ne 'atempo=2.0,atempo=2' -or -not ('BpmDetector' -as [type])){ throw "bpm self-test failed" }
  'self-test ok'; exit
}
[void]$f.ShowDialog()
