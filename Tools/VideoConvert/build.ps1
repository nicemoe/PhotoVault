# 编译「转片」。纯 Win32，只要一套 MSVC + Windows SDK，没有第三方依赖。
#
# 这台机器上用的是便携版 MSVC（loonghao/msvc-kit）。换机器的话把下面
# 三个路径改掉，或者直接在「x64 Native Tools 命令提示符」里跑：
#     cl /nologo /utf-8 /O2 /EHsc /std:c++17 main.cpp /link /SUBSYSTEM:WINDOWS

$ErrorActionPreference = 'Stop'

$kit = "$env:LOCALAPPDATA\loonghao\msvc-kit\data"
$vc  = "$kit\VC\Tools\MSVC\14.44.35207"
$sdk = "$kit\Windows Kits\10"
$ver = '10.0.26100.0'

if (-not (Test-Path "$vc\bin\Hostx64\x64\cl.exe")) {
  throw "没找到 cl.exe：$vc`n改一下脚本顶部的路径，或在 x64 Native Tools 命令提示符里手动编译。"
}

$env:INCLUDE = "$vc\include;$sdk\Include\$ver\ucrt;$sdk\Include\$ver\um;$sdk\Include\$ver\shared;$sdk\Include\$ver\winrt"
$env:LIB     = "$vc\lib\x64;$sdk\Lib\$ver\ucrt\x64;$sdk\Lib\$ver\um\x64"
$env:PATH    = "$vc\bin\Hostx64\x64;$env:PATH"

Push-Location $PSScriptRoot
try {
  New-Item -ItemType Directory -Force -Path build | Out-Null

  # /utf-8：源码里有中文，不加的话 MSVC 会按本地代码页读，字符串全乱
  # /MT   ：静态链接运行库，拷到没装 VC 运行库的机器上也能跑
  # /DUNICODE：让 IDC_ARROW 这类 MAKEINTRESOURCE 宏展开成宽字符版，
  # 否则和显式调用的 LoadCursorW 对不上
  cl /nologo /utf-8 /O2 /MT /EHsc /std:c++17 /W3 /DUNICODE /D_UNICODE `
     /Fo:build\ /Fe:build\转片.exe `
     main.cpp `
     /link /SUBSYSTEM:WINDOWS

  if ($LASTEXITCODE -ne 0) { throw "编译失败" }

  $exe = Get-Item 'build\转片.exe'
  "编译完成：$($exe.FullName)  ($([math]::Round($exe.Length / 1KB)) KB)"
  ""
  "还需要把 ffmpeg.exe 和 ffprobe.exe 放到 exe 旁边："
  "  https://www.gyan.dev/ffmpeg/builds/  下载 release essentials，解压后从 bin 里取这两个文件"
}
finally {
  Pop-Location
}
