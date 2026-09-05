import Foundation

/// 网页端（局域网浏览器访问）。单页应用，纯原生 JS，无外部依赖。
enum WebUI {

    static let page: String = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>百宝箱</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg%20viewBox%3D%220%200%2064%2064%22%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%3E%3CclipPath%20id%3D%22card%22%3E%3Crect%20width%3D%2264%22%20height%3D%2264%22%20rx%3D%2215%22%2F%3E%3C%2FclipPath%3E%3CclipPath%20id%3D%22chest%22%3E%3Cpath%20d%3D%22M7.42%2028.54A24.58%2013.31%200%200%201%2056.58%2028.54Z%22%2F%3E%3Cpath%20d%3D%22M7.42%2028.54H56.58V33.41H7.42Z%22%2F%3E%3Cpath%20d%3D%22M10.11%2030.85H53.89V46.27A3.52%203.52%200%200%201%2050.37%2049.79H13.63A3.52%203.52%200%200%201%2010.11%2046.27Z%22%2F%3E%3C%2FclipPath%3E%3Cg%20clip-path%3D%22url%28%23card%29%22%3E%3Crect%20width%3D%2264%22%20height%3D%2264%22%20fill%3D%22%23E8F3EA%22%2F%3E%3Cellipse%20cx%3D%2226.56%22%20cy%3D%2267.84%22%20rx%3D%2240.64%22%20ry%3D%2225.6%22%20fill%3D%22%23569E5C%22%2F%3E%3Cellipse%20cx%3D%2239.36%22%20cy%3D%2274.56%22%20rx%3D%2242.56%22%20ry%3D%2227.2%22%20fill%3D%22%236CB370%22%2F%3E%3Cg%20fill%3D%22%23FAC94A%22%3E%3Cpath%20d%3D%22M9.73%2013.44L10.6%2015.9L13.06%2016.77L10.6%2017.64L9.73%2020.1L8.86%2017.64L6.4%2016.77L8.86%2015.9Z%22%2F%3E%3Cpath%20d%3D%22M55.17%2017.92L55.8%2019.72L57.6%2020.35L55.8%2020.98L55.17%2022.78L54.54%2020.98L52.74%2020.35L54.54%2019.72Z%22%2F%3E%3Cpath%20d%3D%22M50.56%2011.91L50.99%2013.14L52.22%2013.57L50.99%2014.0L50.56%2015.23L50.13%2014.0L48.9%2013.57L50.13%2013.14Z%22%2F%3E%3C%2Fg%3E%3Cg%20clip-path%3D%22url%28%23chest%29%22%3E%3Cpath%20d%3D%22M10.11%2030.85H53.89V46.27A3.52%203.52%200%200%201%2050.37%2049.79H13.63A3.52%203.52%200%200%201%2010.11%2046.27Z%22%20fill%3D%22%23C07E3F%22%2F%3E%3Crect%20x%3D%2212.16%22%20y%3D%2235.33%22%20width%3D%2239.68%22%20height%3D%2212.29%22%20rx%3D%222.18%22%20fill%3D%22%23D39350%22%2F%3E%3Cpath%20d%3D%22M7.42%2028.54A24.58%2013.31%200%200%201%2056.58%2028.54Z%22%20fill%3D%22%23AC6C33%22%2F%3E%3Cpath%20d%3D%22M7.42%2028.54H56.58V33.41H7.42Z%22%20fill%3D%22%23AC6C33%22%2F%3E%3Crect%20x%3D%2216.38%22%20y%3D%2210%22%20width%3D%225.12%22%20height%3D%2242%22%20rx%3D%220.9%22%20fill%3D%22%23FAC94A%22%2F%3E%3Crect%20x%3D%2220.42%22%20y%3D%2210%22%20width%3D%221.09%22%20height%3D%2242%22%20fill%3D%22%23D0982A%22%2F%3E%3Crect%20x%3D%2242.5%22%20y%3D%2210%22%20width%3D%225.12%22%20height%3D%2242%22%20rx%3D%220.9%22%20fill%3D%22%23FAC94A%22%2F%3E%3Crect%20x%3D%2246.53%22%20y%3D%2210%22%20width%3D%221.09%22%20height%3D%2242%22%20fill%3D%22%23D0982A%22%2F%3E%3C%2Fg%3E%3Crect%20x%3D%227.42%22%20y%3D%2228.93%22%20width%3D%2249.16%22%20height%3D%224.48%22%20rx%3D%221.54%22%20fill%3D%22%23FAC94A%22%2F%3E%3Crect%20x%3D%227.42%22%20y%3D%2231.87%22%20width%3D%2249.16%22%20height%3D%221.54%22%20rx%3D%221.28%22%20fill%3D%22%23D0982A%22%2F%3E%3Crect%20x%3D%228.19%22%20y%3D%2229.31%22%20width%3D%2247.62%22%20height%3D%221.28%22%20rx%3D%220.64%22%20fill%3D%22%23FFE082%22%2F%3E%3Crect%20x%3D%2226.62%22%20y%3D%2231.1%22%20width%3D%2210.75%22%20height%3D%2210.5%22%20rx%3D%222.18%22%20fill%3D%22%23FAC94A%22%2F%3E%3Crect%20x%3D%2226.62%22%20y%3D%2231.1%22%20width%3D%2210.75%22%20height%3D%222.94%22%20rx%3D%221.66%22%20fill%3D%22%23FFE082%22%2F%3E%3Ccircle%20cx%3D%2232%22%20cy%3D%2236.86%22%20r%3D%221.54%22%20fill%3D%22%23523319%22%2F%3E%3Cpath%20d%3D%22M31.04%2037.5H32.96L32.58%2040.45H31.42Z%22%20fill%3D%22%23523319%22%2F%3E%3C%2Fg%3E%3C%2Fsvg%3E">
<style>
:root{
  --bg:#F4F5F7; --surface:#FFFFFF; --fill:#EBEDF1; --line:#E4E7EC;
  --text:#12141A; --sub:#767E90; --accent:#2F6FED; --danger:#E8453C;
  --radius:18px;
}
@media (prefers-color-scheme: dark){
  :root{
    --bg:#0E1014; --surface:#191C22; --fill:#22262E; --line:#2A2F39;
    --text:#F2F4F8; --sub:#8B93A6; --accent:#5B8DFF; --danger:#FF6B60;
  }
}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;padding:0}
body{
  background:var(--bg); color:var(--text);
  font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;
  padding-bottom:60px;
}
button{font-family:inherit;font-size:inherit;cursor:pointer;border:0;background:none;color:inherit}
.wrap{max-width:1080px;margin:0 auto;padding:0 20px}

/* 顶部 */
header{
  position:sticky;top:0;z-index:20;background:var(--bg);
  border-bottom:1px solid var(--line);
}
.hbar{display:flex;align-items:center;gap:12px;height:60px}
/* logo 就是 App 图标本身，不再套蓝底 */
.logo{width:32px;height:32px;flex:none;line-height:0}
.logo svg{width:32px;height:32px;display:block}
.htitle{font-weight:700;font-size:16.5px;letter-spacing:-.2px}
.hsub{font-size:12.5px;color:var(--sub);margin-top:1px}
.spacer{flex:1}

/* 面包屑 */
.crumbs{display:flex;align-items:center;gap:6px;flex-wrap:wrap;padding:14px 0 4px;font-size:13.5px;color:var(--sub)}
.crumbs button{color:var(--accent);font-weight:600}
.crumbs .sep{opacity:.5}
.crumbs .cur{color:var(--text);font-weight:600}

/* 工具条 */
.toolbar{display:flex;gap:10px;flex-wrap:wrap;padding:12px 0 18px}
.btn{
  display:inline-flex;align-items:center;gap:7px;height:34px;padding:0 14px;
  border-radius:10px;background:var(--fill);font-weight:600;font-size:13.5px;
  transition:transform .12s ease,opacity .12s ease;
}
.btn:active{transform:scale(.97)}
.btn.primary{background:var(--accent);color:#fff}
.btn.danger{color:var(--danger)}
.btn svg{width:15px;height:15px;fill:currentColor}

/* 卡片网格 */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:18px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);overflow:hidden;display:flex;flex-direction:column;transition:border-color .12s,transform .12s}
.card.dropping{border-color:var(--accent);transform:scale(1.02)}
.card.dropping .cover::after{content:"松开上传到这里";position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
  background:color-mix(in srgb,var(--accent) 78%,transparent);color:#fff;font-size:13.5px;font-weight:700}
/* 正方形封面不要靠 aspect-ratio：部分浏览器下图片的固有高度会把它顶开，
   有图的封面就比空封面高，同一行的卡片和按钮跟着错位。
   height:0 + padding-top:100% 的高度完全来自 padding，内容绝对定位填充，
   无论图片多大都撑不开。 */
.cover{position:relative;width:100%;height:0;padding-top:100%;flex:0 0 auto;
  overflow:hidden;background:var(--fill);cursor:pointer}
.tiles{position:absolute;inset:0;display:grid;gap:2px}
.tiles.c1{grid-template-columns:1fr;grid-template-rows:1fr}
.tiles.c2{grid-template-columns:1fr 1fr;grid-template-rows:1fr}
.tiles.c3{grid-template-columns:1.6fr 1fr;grid-template-rows:1fr 1fr}
.tiles.c3 img:first-child{grid-row:span 2}
.tiles.c4{grid-template-columns:1fr 1fr;grid-template-rows:1fr 1fr}
.tiles img{width:100%;height:100%;min-width:0;min-height:0;object-fit:cover;display:block}
.cover .empty{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;opacity:.3}
.cover .empty svg{width:34%;max-width:58px;fill:currentColor}
.dot{position:absolute;top:10px;left:10px;width:22px;height:22px;border-radius:50%;background:rgba(255,255,255,.85);display:flex;align-items:center;justify-content:center}
.dot i{width:9px;height:9px;border-radius:50%;display:block}
/* 撑满卡片剩余高度，配合 .cactions 的 margin-top:auto，
   即使某张卡名字换行或按钮换行，同一行里所有卡的按钮也都贴着底部对齐 */
.cbody{padding:12px 13px 13px;display:flex;flex-direction:column;flex:1;min-height:0}
.cname{font-weight:650;font-size:14.5px;letter-spacing:-.1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
.cmeta{font-size:12.5px;color:var(--sub);margin-top:2px}
/* gap 和内边距收紧，让「移动/重命名/删除」在窄卡片上也能排成一行；
   万一还是换行，margin-top:auto 也能保证同一行卡片的按钮对齐 */
.cactions{display:flex;gap:3px;margin-top:auto;padding-top:10px;flex-wrap:wrap}
.mini{height:26px;padding:0 7px;border-radius:8px;background:var(--fill);font-size:12.5px;font-weight:600;color:var(--sub);white-space:nowrap}
.mini:active{transform:scale(.96)}
.mini.danger{color:var(--danger)}

/* 照片网格 */
.photos{display:grid;grid-template-columns:repeat(auto-fill,minmax(118px,1fr));gap:8px}
/* 同上，照片格也不用 aspect-ratio */
.ph{position:relative;width:100%;height:0;padding-top:100%;border-radius:12px;overflow:hidden;background:var(--fill)}
.ph img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;display:block}
.ph .del{position:absolute;top:6px;right:6px;width:26px;height:26px;border-radius:50%;background:rgba(0,0,0,.55);color:#fff;font-size:15px;line-height:26px;text-align:center;opacity:0;transition:opacity .15s}
.ph:hover .del,.ph:active .del{opacity:1}
/* 视频角标放左下，和右上角的删除键错开 */
.ph .vbadge{position:absolute;left:6px;bottom:6px;padding:2px 7px;border-radius:999px;
  background:rgba(0,0,0,.55);color:#fff;font-size:11.5px;font-weight:600;
  font-variant-numeric:tabular-nums;cursor:pointer}

/* 上传区 */
.drop{
  border:2px dashed var(--line);border-radius:var(--radius);padding:30px 20px;text-align:center;
  background:var(--surface);margin-bottom:18px;transition:border-color .15s,background .15s;
}
.drop .up svg{width:34px;height:34px;fill:var(--sub);opacity:.65}
.drop h3{margin:10px 0 4px;font-size:15.5px}
.drop p{margin:0 0 14px;color:var(--sub);font-size:13px}

/* 全页拖放遮罩 */
.dragmask{position:fixed;inset:0;z-index:70;display:none;align-items:center;justify-content:center;
  background:rgba(12,16,24,.5);padding:24px;pointer-events:none}
.dragmask.on{display:flex}
.dragbox{background:var(--surface);border:2px dashed var(--accent);border-radius:22px;padding:32px 38px;text-align:center;max-width:420px}
.dragbox svg{width:40px;height:40px;fill:var(--accent)}
.dragbox h3{margin:12px 0 5px;font-size:17px;color:var(--text)}
.dragbox p{margin:0;font-size:13.5px;color:var(--sub);line-height:1.55}
/* 目录页不遮挡卡片，只在顶部给一条提示 */
.dragmask.hintmode{background:transparent;align-items:flex-start;padding-top:76px}
.dragmask.hintmode .dragbox{padding:13px 20px;border-width:1px;border-style:solid}
.dragmask.hintmode .dragbox svg{display:none}
.dragmask.hintmode .dragbox h3{margin:0 0 2px;font-size:14.5px}
.dragmask.hintmode .dragbox p{font-size:12.5px}

/* 上传进度 */
#uploading{
  position:fixed;left:50%;bottom:26px;transform:translateX(-50%);z-index:90;min-width:280px;max-width:88vw;
  background:var(--surface);border:1px solid var(--line);border-radius:16px;padding:13px 16px;display:none;
}
#uploading.on{display:block}
#uploading .urow{display:flex;align-items:center;gap:10px;font-size:13.5px;font-weight:600}
#uploading .upct{margin-left:auto;color:var(--sub);font-variant-numeric:tabular-nums}
#uploading .ub{height:6px;border-radius:3px;background:var(--fill);overflow:hidden;margin-top:9px}
#uploading .ub i{display:block;height:100%;width:0;background:var(--accent);transition:width .15s}

/* 空状态 */
.empty-state{text-align:center;padding:64px 20px;color:var(--sub)}
.empty-state .ico svg{width:46px;height:46px;fill:currentColor;opacity:.4}
.empty-state h3{color:var(--text);margin:14px 0 6px;font-size:16px}
.empty-state p{margin:0;font-size:13.5px}

/* 弹层 */
.mask{position:fixed;inset:0;background:rgba(0,0,0,.45);display:none;align-items:center;justify-content:center;z-index:60;padding:20px}
.mask.on{display:flex}
.modal{background:var(--surface);border-radius:20px;width:100%;max-width:380px;padding:20px;max-height:80vh;overflow:auto}
.modal h3{margin:0 0 14px;font-size:16.5px}
.modal input{
  width:100%;height:46px;border-radius:12px;border:1px solid var(--line);background:var(--bg);
  color:var(--text);padding:0 14px;font-size:15px;font-family:inherit;outline:none;
}
.modal input:focus{border-color:var(--accent)}
.mrow{display:flex;gap:10px;margin-top:16px}
.mrow .btn{flex:1;justify-content:center}
.pick{display:flex;align-items:center;gap:10px;width:100%;padding:12px;border-radius:12px;background:var(--bg);margin-bottom:8px;text-align:left}
.pick i{width:10px;height:10px;border-radius:50%;flex:none}
.pick.cur{opacity:.4;pointer-events:none}

/* 全屏预览 */
.viewer{position:fixed;inset:0;background:rgba(0,0,0,.94);display:none;align-items:center;justify-content:center;z-index:80}
.viewer.on{display:flex}
.viewer img,.viewer video{max-width:96vw;max-height:92vh;object-fit:contain}
.viewer .x{position:absolute;top:16px;right:18px;color:#fff;font-size:30px;line-height:1;opacity:.85}

/* toast */
#toast{
  position:fixed;left:50%;bottom:26px;transform:translateX(-50%) translateY(20px);
  background:#1B1F27;color:#fff;padding:11px 18px;border-radius:999px;font-size:14px;font-weight:500;
  opacity:0;pointer-events:none;transition:opacity .2s,transform .2s;z-index:100;
}
#toast.on{opacity:1;transform:translateX(-50%) translateY(0)}
</style>
</head>
<body>

<header>
  <div class="wrap hbar">
    <div class="logo"><svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><clipPath id="card"><rect width="64" height="64" rx="15"/></clipPath><clipPath id="chest"><path d="M7.42 28.54A24.58 13.31 0 0 1 56.58 28.54Z"/><path d="M7.42 28.54H56.58V33.41H7.42Z"/><path d="M10.11 30.85H53.89V46.27A3.52 3.52 0 0 1 50.37 49.79H13.63A3.52 3.52 0 0 1 10.11 46.27Z"/></clipPath><g clip-path="url(#card)"><rect width="64" height="64" fill="#E8F3EA"/><ellipse cx="26.56" cy="67.84" rx="40.64" ry="25.6" fill="#569E5C"/><ellipse cx="39.36" cy="74.56" rx="42.56" ry="27.2" fill="#6CB370"/><g fill="#FAC94A"><path d="M9.73 13.44L10.6 15.9L13.06 16.77L10.6 17.64L9.73 20.1L8.86 17.64L6.4 16.77L8.86 15.9Z"/><path d="M55.17 17.92L55.8 19.72L57.6 20.35L55.8 20.98L55.17 22.78L54.54 20.98L52.74 20.35L54.54 19.72Z"/><path d="M50.56 11.91L50.99 13.14L52.22 13.57L50.99 14.0L50.56 15.23L50.13 14.0L48.9 13.57L50.13 13.14Z"/></g><g clip-path="url(#chest)"><path d="M10.11 30.85H53.89V46.27A3.52 3.52 0 0 1 50.37 49.79H13.63A3.52 3.52 0 0 1 10.11 46.27Z" fill="#C07E3F"/><rect x="12.16" y="35.33" width="39.68" height="12.29" rx="2.18" fill="#D39350"/><path d="M7.42 28.54A24.58 13.31 0 0 1 56.58 28.54Z" fill="#AC6C33"/><path d="M7.42 28.54H56.58V33.41H7.42Z" fill="#AC6C33"/><rect x="16.38" y="10" width="5.12" height="42" rx="0.9" fill="#FAC94A"/><rect x="20.42" y="10" width="1.09" height="42" fill="#D0982A"/><rect x="42.5" y="10" width="5.12" height="42" rx="0.9" fill="#FAC94A"/><rect x="46.53" y="10" width="1.09" height="42" fill="#D0982A"/></g><rect x="7.42" y="28.93" width="49.16" height="4.48" rx="1.54" fill="#FAC94A"/><rect x="7.42" y="31.87" width="49.16" height="1.54" rx="1.28" fill="#D0982A"/><rect x="8.19" y="29.31" width="47.62" height="1.28" rx="0.64" fill="#FFE082"/><rect x="26.62" y="31.1" width="10.75" height="10.5" rx="2.18" fill="#FAC94A"/><rect x="26.62" y="31.1" width="10.75" height="2.94" rx="1.66" fill="#FFE082"/><circle cx="32" cy="36.86" r="1.54" fill="#523319"/><path d="M31.04 37.5H32.96L32.58 40.45H31.42Z" fill="#523319"/></g></svg></div>
    <div>
      <div class="htitle">百宝箱</div>
      <div class="hsub" id="devinfo">连接中…</div>
    </div>
    <div class="spacer"></div>
    <button class="mini" onclick="load()">刷新</button>
  </div>
</header>

<div class="wrap">
  <nav class="crumbs" id="crumbs"></nav>
  <div class="toolbar" id="toolbar"></div>
  <main id="main"></main>
</div>

<div class="dragmask" id="dragmask">
  <div class="dragbox">
    <svg viewBox="0 0 24 24"><path d="M12 3l5.5 5.5h-3.5V16h-4V8.5H6.5L12 3zM4 18h16v3H4z"/></svg>
    <h3 id="dragTitle">松开即可上传</h3>
    <p id="dragHint">支持一次拖入多张图片，也可以直接拖整个文件夹</p>
  </div>
</div>

<div id="uploading">
  <div class="urow"><span id="ustat">上传中…</span><span class="upct" id="upct">0%</span></div>
  <div class="ub"><i id="ufill"></i></div>
</div>

<div class="mask" id="mask"><div class="modal" id="modal"></div></div>
<div class="viewer" id="viewer" onclick="closeViewer()"><span class="x">&times;</span><img id="viewerImg" alt="">
  <!-- 播放器上的点击不能冒泡到遮罩，否则一按播放键整层就关了 -->
  <video id="viewerVideo" controls playsinline style="display:none" onclick="event.stopPropagation()"></video>
</div>
<div id="toast"></div>

<script>
let state = {groups: []};
let view = {level: 'groups', groupId: null, folderId: null};
let folderCache = null;

const ICON = {
  image:  '<svg viewBox="0 0 24 24"><path d="M4 4h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2zm0 2v9.2l4.2-4.2 3.6 3.6L15.4 11l4.6 4.6V6H4zm4.6 1a1.7 1.7 0 1 1 0 3.4 1.7 1.7 0 0 1 0-3.4z"/></svg>',
  folder: '<svg viewBox="0 0 24 24"><path d="M3 4h6l2 2h10a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1z"/></svg>',
  photo:  '<svg viewBox="0 0 24 24"><path d="M9 3h6l1.5 2H20a1 1 0 0 1 1 1v13a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h3.5L9 3zm3 5a5 5 0 1 0 0 10 5 5 0 0 0 0-10z"/></svg>',
  upload: '<svg viewBox="0 0 24 24"><path d="M12 3l5.5 5.5h-3.5V16h-4V8.5H6.5L12 3zM4 18h16v3H4z"/></svg>'
};

const $ = s => document.querySelector(s);
const esc = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

function toast(msg){
  const t = $('#toast');
  t.textContent = msg; t.classList.add('on');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.remove('on'), 2000);
}

async function api(path, body){
  const res = await fetch(path, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body || {})
  });
  const json = await res.json().catch(() => ({ok:false, error:'网络异常'}));
  if(!json.ok) toast(json.error || '操作失败');
  return json;
}

async function load(){
  try{
    const res = await fetch('/api/state', {cache:'no-store'});
    state = await res.json();
    $('#devinfo').textContent = `${state.device} · 共 ${state.totalPhotos} 张照片`;
    if(view.level === 'photos'){
      const r = await fetch('/api/folder?id=' + view.folderId, {cache:'no-store'});
      if(r.ok){ folderCache = await r.json(); } else { view = {level:'groups'}; }
    }
    render();
  }catch(e){
    $('#devinfo').textContent = '连接断开，请检查手机端是否仍在传输页面';
  }
}

/* ---------- 面包屑 ---------- */
function renderCrumbs(){
  const g = state.groups.find(x => x.id === view.groupId);
  let html = '';
  if(view.level === 'groups'){
    html = '<span class="cur">全部分组</span>';
  }else if(view.level === 'folders'){
    html = `<button onclick="go('groups')">全部分组</button><span class="sep">/</span><span class="cur">${esc(g ? g.name : '')}</span>`;
  }else{
    // 目录可以嵌套，中间每一层都要能点回去
    const chain = (folderCache && folderCache.path) || [];
    html = `<button onclick="go('groups')">全部分组</button><span class="sep">/</span>`
         + `<button onclick="go('folders','${view.groupId}')">${esc(g ? g.name : '')}</button>`
         + chain.map(n => `<span class="sep">/</span><button onclick="go('photos','${view.groupId}','${n.id}')">${esc(n.name)}</button>`).join('')
         + `<span class="sep">/</span><span class="cur">${esc(folderCache ? folderCache.name : '')}</span>`;
  }
  $('#crumbs').innerHTML = html;
}

/* ---------- 工具条 ---------- */
function renderToolbar(){
  const plus = '<svg viewBox="0 0 24 24"><path d="M11 5h2v6h6v2h-6v6h-2v-6H5v-2h6z"/></svg>';
  let html = '';
  if(view.level === 'groups'){
    html = `<button class="btn primary" onclick="promptCreateGroup()">${plus}新建分组</button>`;
  }else if(view.level === 'folders'){
    // 分组内部只提供「新建目录」。新建分组是上一层的事，
    // 放在这里既和当前上下文无关，也会让层级看着混乱。
    html = `<button class="btn primary" onclick="promptCreateFolder()">${plus}新建目录</button>`;
  }else{
    // 目录里既能传图，也能再建子目录
    html = `<button class="btn primary" onclick="filePick()">${plus}选择文件上传</button>`
         + `<button class="btn" onclick="promptCreateFolder()">${plus}新建子目录</button>`;
  }
  $('#toolbar').innerHTML = html;
}

/* ---------- 视图 ---------- */
function coverHTML(ids, color){
  const n = Math.min(ids.length, 4);
  const dot = color ? dotHTML(color) : '';
  // 图片统一包在绝对定位的 .tiles 里，撑不开外面的正方形 .cover
  if(n === 0){
    return `<div class="cover"><div class="empty">${ICON.image}</div>${dot}</div>`;
  }
  const imgs = ids.slice(0, n).map(id => `<img loading="lazy" src="/thumb?id=${id}&s=360" alt="">`).join('');
  return `<div class="cover"><div class="tiles c${n}">${imgs}</div>${dot}</div>`;
}
function dotHTML(color){ return `<span class="dot"><i style="background:${color}"></i></span>`; }

function render(){
  renderCrumbs();
  renderToolbar();
  const main = $('#main');

  if(view.level === 'groups'){
    if(!state.groups.length){
      main.innerHTML = emptyHTML(ICON.folder,'还没有分组','先创建一个分组，再在分组里建目录、上传图片');
      return;
    }
    main.innerHTML = '<div class="grid">' + state.groups.map(g => `
      <div class="card">
        <div onclick="go('folders','${g.id}')">${coverHTML(g.cover, g.color)}</div>
        <div class="cbody">
          <div class="cname" onclick="go('folders','${g.id}')">${esc(g.name)}</div>
          <div class="cmeta">${g.folderCount} 个目录 · ${g.photoCount} 张</div>
          <div class="cactions">
            <button class="mini" onclick="promptRenameGroup('${g.id}')">重命名</button>
            <button class="mini danger" onclick="removeGroup('${g.id}')">删除</button>
          </div>
        </div>
      </div>`).join('') + '</div>';
    return;
  }

  if(view.level === 'folders'){
    const g = state.groups.find(x => x.id === view.groupId);
    if(!g){ go('groups'); return; }
    // 只列直接挂在分组下的那层，子目录在各自的父目录里显示
    const roots = g.folders.filter(f => !f.parentId);
    if(!roots.length){
      main.innerHTML = emptyHTML(ICON.folder,'这个分组还没有目录','目录用来分类存放图片，里面还能再建子目录');
      return;
    }
    main.innerHTML = '<div class="grid">' + roots.map(f => folderCardHTML(g.id, f)).join('') + '</div>';
    return;
  }

  // 目录内部：先列子目录，再列图片
  const f = folderCache;
  const list = (f && f.assets) || [];
  const subs = (f && f.subfolders) || [];
  const gid = (f && f.groupId) || view.groupId;

  main.innerHTML = `
    ${subs.length ? '<div class="grid">' + subs.map(s => folderCardHTML(gid, s)).join('') + '</div>' : ''}
    <div class="drop" id="drop">
      <div class="up">${ICON.upload}</div>
      <h3>把图片或视频拖到这里上传</h3>
      <p>一次可以拖多张；拖一整个文件夹进来会按原来的层级建好子目录</p>
      <button class="btn primary" style="display:inline-flex" onclick="filePick()">选择文件</button>
    </div>
    ${list.length ? '<div class="photos">' + list.map(a => `
      <div class="ph">
        <img loading="lazy" src="/thumb?id=${a.id}&s=380" alt="" onclick="openViewer('${a.id}','${a.kind || 'image'}')">
        ${a.kind === 'video' ? `<span class="vbadge" onclick="openViewer('${a.id}','video')">▶ ${a.durationText || ''}</span>` : ''}
        <span class="del" onclick="removeAsset('${a.id}')">&times;</span>
      </div>`).join('') + '</div>'
    : (subs.length ? '' : emptyHTML(ICON.photo,'这个目录还没有内容','上传的图片和视频会立刻出现在手机 App 里'))}
  `;
}

// 目录卡片：分组内和目录内共用一套
function folderCardHTML(groupId, f){
  const meta = f.subfolderCount
    ? `${f.subfolderCount} 个子目录 · 共 ${f.totalPhotoCount} 张`
    : `${f.photoCount} 张照片`;
  return `
    <div class="card" ondragover="cardDragOver(event,this)" ondragleave="cardDragLeave(event,this)" ondrop="cardDrop(event,this,'${f.id}')">
      <div onclick="go('photos','${groupId}','${f.id}')">${coverHTML(f.cover, null)}</div>
      <div class="cbody">
        <div class="cname" onclick="go('photos','${groupId}','${f.id}')">${esc(f.name)}</div>
        <div class="cmeta">${meta}</div>
        <div class="cactions">
          <button class="mini" onclick="promptMoveFolder('${f.id}')">移动</button>
          <button class="mini" onclick="promptRenameFolder('${f.id}','${esc(f.name)}')">重命名</button>
          <button class="mini danger" onclick="removeFolder('${f.id}')">删除</button>
        </div>
      </div>
    </div>`;
}

function emptyHTML(icon, title, msg){
  return `<div class="empty-state"><div class="ico">${icon}</div><h3>${title}</h3><p>${msg}</p></div>`;
}

function go(level, groupId, folderId){
  view = {level, groupId: groupId || null, folderId: folderId || null};
  if(level === 'photos'){
    fetch('/api/folder?id=' + folderId, {cache:'no-store'})
      .then(r => r.json()).then(j => { folderCache = j; render(); });
  }else{
    folderCache = null;
    render();
  }
  window.scrollTo({top:0});
}

/* ---------- 弹层 ---------- */
function closeModal(){ $('#mask').classList.remove('on'); }
$('#mask').addEventListener('click', e => { if(e.target.id === 'mask') closeModal(); });

function inputModal(title, placeholder, value, onOK){
  $('#modal').innerHTML = `
    <h3>${title}</h3>
    <input id="mInput" placeholder="${placeholder}" value="${esc(value || '')}" autocomplete="off">
    <div class="mrow">
      <button class="btn" onclick="closeModal()">取消</button>
      <button class="btn primary" id="mOK">确定</button>
    </div>`;
  $('#mask').classList.add('on');
  const input = $('#mInput');
  setTimeout(() => { input.focus(); input.select(); }, 60);
  const submit = () => { const v = input.value.trim(); if(!v){ toast('名称不能为空'); return; } closeModal(); onOK(v); };
  $('#mOK').onclick = submit;
  input.onkeydown = e => { if(e.key === 'Enter') submit(); };
}

function promptCreateGroup(){
  inputModal('新建分组', '例如：旅行 / 工作 / 灵感', '', async name => {
    await api('/api/group/create', {name}); toast('分组已创建'); load();
  });
}
function promptRenameGroup(id){
  const g = state.groups.find(x => x.id === id);
  inputModal('重命名分组', '分组名称', g ? g.name : '', async name => {
    await api('/api/group/rename', {id, name}); load();
  });
}
async function removeGroup(id){
  const g = state.groups.find(x => x.id === id);
  if(!confirm(`删除分组「${g ? g.name : ''}」？其中所有目录和图片都会被删除。`)) return;
  await api('/api/group/delete', {id}); toast('已删除'); load();
}

function promptCreateFolder(){
  const gid = view.groupId;
  // 在某个目录里点新建，建的是它的子目录；在分组页点，建在分组根下
  const parentId = view.level === 'photos' ? view.folderId : null;
  inputModal(parentId ? '新建子目录' : '新建目录', '例如：2025 京都', '', async name => {
    await api('/api/folder/create', {groupId: gid, name, parentId});
    toast('目录已创建');
    if(parentId) go('photos', gid, parentId); else load();
  });
}
function promptRenameFolder(id, current){
  inputModal('重命名目录', '目录名称', current, async name => {
    await api('/api/folder/rename', {id, name}); load();
  });
}
async function removeFolder(id){
  if(!confirm('删除该目录？里面的子目录和图片都会被一起删除。')) return;
  await api('/api/folder/delete', {id}); toast('已删除'); load();
}

// 目标可以是任意分组的根，也可以是任意目录。
// 自己和自己的子树不能选——移进去这棵子树就从树上断开了。
function promptMoveFolder(id){
  let rows = '';
  for(const g of state.groups){
    rows += `<button class="pick" onclick="doMoveFolder('${id}','${g.id}',null)">
      <i style="background:${g.color}"></i><span>${esc(g.name)}</span>
      <span style="margin-left:auto;color:var(--sub);font-size:12.5px">分组根</span>
    </button>`;

    const walk = (parentId, depth) => {
      for(const f of g.folders.filter(x => (x.parentId || null) === parentId)){
        const self = f.id === id;
        rows += `<button class="pick${self ? ' cur' : ''}" ${self ? '' : `onclick="doMoveFolder('${id}','${g.id}','${f.id}')"`}>
          <span style="width:${depth * 16}px"></span>
          <span>${esc(f.name)}</span>
          <span style="margin-left:auto;color:var(--sub);font-size:12.5px">${self ? '自身' : f.totalPhotoCount + ' 张'}</span>
        </button>`;
        // 自己的子树全都不能选，展开只是噪音
        if(!self) walk(f.id, depth + 1);
      }
    };
    walk(null, 1);
  }
  $('#modal').innerHTML = `<h3>移动到</h3>` + rows
    + `<div class="mrow"><button class="btn" onclick="closeModal()">取消</button></div>`;
  $('#mask').classList.add('on');
}
async function doMoveFolder(id, groupId, parentId){
  closeModal();
  await api('/api/folder/move', {id, groupId, parentId: parentId || null});
  toast('已移动');
  load();
}

async function removeAsset(id){
  if(!folderCache) return;
  await api('/api/asset/delete', {folderId: folderCache.id, id});
  go('photos', view.groupId, view.folderId);
}

/* ---------- 预览 ---------- */
function openViewer(id, kind){
  const img = $('#viewerImg'), vid = $('#viewerVideo');
  if(kind === 'video'){
    img.style.display = 'none'; img.src = '';
    vid.style.display = 'block';
    // 服务端支持 Range，所以这里能直接拖进度条，不用等整个文件下完
    vid.src = '/photo?id=' + id;
    vid.play().catch(() => {});
  }else{
    vid.pause(); vid.removeAttribute('src'); vid.load();
    vid.style.display = 'none';
    img.style.display = 'block';
    img.src = '/photo?id=' + id;
  }
  $('#viewer').classList.add('on');
}
function closeViewer(){
  $('#viewer').classList.remove('on');
  $('#viewerImg').src = '';
  const vid = $('#viewerVideo');
  // 光暂停不够：不把 src 摘掉，浏览器会继续在后台把整个视频拉完
  vid.pause(); vid.removeAttribute('src'); vid.load();
}

/* ---------- 选择文件 ---------- */
const picker = document.createElement('input');
picker.type = 'file';
picker.accept = 'image/*,video/*';
picker.multiple = true;
picker.onchange = () => { if(picker.files.length) upload(picker.files); picker.value = ''; };
function filePick(){ picker.click(); }

/* ---------- 拖拽 ---------- */
// 一次可以拖多张图片，也可以拖整个文件夹（递归取里面的图片）。
// 在目录页拖到页面任意位置即可；在分组页可以直接拖到某个目录卡片上。

function hasFiles(e){
  const dt = e.dataTransfer;
  if(!dt) return false;
  return [...(dt.types || [])].includes('Files');
}

let dragDepth = 0;

function dragMaskText(){
  const title = $('#dragTitle'), hint = $('#dragHint');
  if(view.level === 'photos'){
    title.textContent = `松开上传到「${folderCache ? folderCache.name : '当前目录'}」`;
    hint.textContent = '支持一次拖入多张图片，也可以直接拖整个文件夹';
  }else if(view.level === 'folders'){
    title.textContent = '把图片拖到某个目录卡片上';
    hint.textContent = '松开即可上传到那个目录；也可以先点进目录再拖';
  }else{
    title.textContent = '请先进入一个目录';
    hint.textContent = '图片需要放在「分组 → 目录」下面';
  }
}

function showDragMask(){
  dragMaskText();
  const mask = $('#dragmask');
  // 目录页要能看清卡片往上拖，所以只给顶部提示，不盖全屏
  mask.classList.toggle('hintmode', view.level === 'folders');
  mask.classList.add('on');
}
function hideDragMask(){ dragDepth = 0; $('#dragmask').classList.remove('on'); }

window.addEventListener('dragenter', e => {
  if(!hasFiles(e)) return;
  e.preventDefault(); dragDepth++; showDragMask();
});
window.addEventListener('dragover', e => {
  if(!hasFiles(e)) return;
  e.preventDefault();
  e.dataTransfer.dropEffect = 'copy';
});
window.addEventListener('dragleave', e => {
  if(!hasFiles(e)) return;
  dragDepth = Math.max(0, dragDepth - 1);
  if(dragDepth === 0) hideDragMask();
});
window.addEventListener('drop', async e => {
  if(!hasFiles(e)) return;
  e.preventDefault();
  hideDragMask();
  if(view.level !== 'photos'){
    toast(view.level === 'folders' ? '请拖到某个目录卡片上' : '请先进入一个目录');
    return;
  }
  upload(await collectFiles(e.dataTransfer));
});

// 目录卡片作为投放目标
function cardDragOver(e, el){
  if(!hasFiles(e)) return;
  e.preventDefault(); e.stopPropagation();
  e.dataTransfer.dropEffect = 'copy';
  el.classList.add('dropping');
}
function cardDragLeave(e, el){
  if(el.contains(e.relatedTarget)) return;
  el.classList.remove('dropping');
}
async function cardDrop(e, el, folderId){
  if(!hasFiles(e)) return;
  e.preventDefault(); e.stopPropagation();
  el.classList.remove('dropping');
  hideDragMask();
  upload(await collectFiles(e.dataTransfer), folderId);
}

// webkitGetAsEntry 必须在 drop 事件里同步调用，之后条目就失效了
async function collectFiles(dt){
  const entries = [];
  if(dt.items && dt.items.length){
    for(const item of dt.items){
      if(item.kind !== 'file') continue;
      const entry = item.webkitGetAsEntry ? item.webkitGetAsEntry() : null;
      if(entry) entries.push(entry);
    }
  }
  if(!entries.length) return [...dt.files];

  const out = [];
  for(const entry of entries) await walkEntry(entry, out, '');
  return out;
}

// prefix 是这个条目所在的相对路径。拖一整个文件夹进来时，
// 要把层级带上传给手机端按原样重建，而不是把里面的文件全抖到当前目录。
function walkEntry(entry, out, prefix){
  return new Promise(resolve => {
    if(entry.isFile){
      entry.file(f => {
        try{ f.relPath = prefix + f.name; }catch(e){}
        out.push(f);
        resolve();
      }, () => resolve());
    }else if(entry.isDirectory){
      const reader = entry.createReader();
      const sub = prefix + entry.name + '/';
      const readNext = () => reader.readEntries(async batch => {
        if(!batch.length){ resolve(); return; }
        for(const child of batch) await walkEntry(child, out, sub);
        readNext();
      }, () => resolve());
      readNext();
    }else{
      resolve();
    }
  });
}

/* ---------- 上传 ---------- */
// 和手机端 MediaFormats.videoExtensions 保持一致
const VIDEO_EXT = /\.(mp4|m4v|mov|qt|3gp|3g2|m4p|mts|m2ts|ts|mpe?g|mpe|m2v|mxf|dv|avi|mkv|webm|wmv|asf|flv|f4v|rm|rmvb|vob|ogv|ogm|divx|xvid|amv|m2p)$/i;
// 图片这边手机端走 ImageIO，它支持什么就认什么，所以列得宽一点，
// 含各家 RAW；真解不出来的会在服务端被跳过，只是白传一次
const IMAGE_EXT = /\.(jpe?g|jpe|jfif|png|apng|gif|webp|bmp|dib|tiff?|heic|heif|heics|avci|avif|ico|cur|psd|jp2|j2k|jpf|jpx|jpm|tga|pict|pct|exr|hdr|dng|cr2|cr3|nef|nrw|arw|srf|sr2|raf|orf|rw2|pef|ptx|srw|3fr|erf|mrw|mos|x3f|iiq|k25|kdc|dcr|fff|rwl|mef)$/i;

function isVideoFile(f){
  if(f.type) return f.type.startsWith('video/');
  return VIDEO_EXT.test(f.name);
}
function isMedia(f){
  // 浏览器给了 type 就信它，同时扩展名也放行——很多从网上存下来的
  // 文件 type 是空的或者 application/octet-stream
  if(f.type && (f.type.startsWith('image/') || f.type.startsWith('video/'))) return true;
  return IMAGE_EXT.test(f.name) || VIDEO_EXT.test(f.name);
}

// 分批发送。手机端现在是边收边写盘的，不再受内存限制，但一批太大的话
// 中途断网要重传的量也大，所以图片仍按 20MB 一批；视频单独成批，
// 一个文件一批，进度条也才走得准。
const BATCH_MAX_BYTES = 20 * 1024 * 1024;
const BATCH_MAX_FILES = 25;

function makeBatches(files){
  const batches = [];
  let current = [], size = 0;
  const flush = () => { if(current.length){ batches.push(current); current = []; size = 0; } };

  for(const f of files){
    if(isVideoFile(f)){ flush(); batches.push([f]); continue; }
    if(current.length && (size + f.size > BATCH_MAX_BYTES || current.length >= BATCH_MAX_FILES)) flush();
    current.push(f); size += f.size;
  }
  flush();
  return batches;
}

function showUploadProgress(text, ratio){
  $('#uploading').classList.add('on');
  $('#ustat').textContent = text;
  const pct = Math.min(100, Math.round(ratio * 100));
  $('#upct').textContent = pct + '%';
  $('#ufill').style.width = pct + '%';
}
function hideUploadProgress(){
  setTimeout(() => $('#uploading').classList.remove('on'), 600);
}

let uploading = false;

async function upload(fileList, folderId){
  const target = folderId || view.folderId;
  if(!target){ toast('请先进入一个目录'); return; }
  if(uploading){ toast('还有一批正在上传，请稍候'); return; }

  const all = [...fileList];
  const media = all.filter(isMedia);
  const ignored = all.length - media.length;
  if(!media.length){ toast('没有找到可上传的图片或视频'); return; }

  uploading = true;
  const batches = makeBatches(media);
  const totalBytes = media.reduce((sum, f) => sum + f.size, 0) || 1;
  let sentBytes = 0, saved = 0, skipped = ignored, failed = 0;

  showUploadProgress(`上传 ${media.length} 个文件`, 0);

  for(const batch of batches){
    const batchBytes = batch.reduce((sum, f) => sum + f.size, 0);
    try{
      const progress = loaded =>
        showUploadProgress(`上传中 ${saved} / ${media.length}`, (sentBytes + loaded) / totalBytes);
      // 视频是一个文件一批，走直传；图片仍然打包成 multipart
      const res = (batch.length === 1 && isVideoFile(batch[0]))
        ? await sendFile(batch[0], target, progress)
        : await sendBatch(batch, target, progress);
      if(res && res.ok){ saved += res.saved; skipped += res.skipped || 0; }
      else { failed += batch.length; }
    }catch(err){
      failed += batch.length;
    }
    sentBytes += batchBytes;
    showUploadProgress(`上传中 ${saved} / ${media.length}`, sentBytes / totalBytes);
  }

  uploading = false;
  hideUploadProgress();

  const notes = [];
  if(skipped) notes.push(`${skipped} 个格式不支持`);
  if(failed) notes.push(`${failed} 个失败`);
  toast(`已上传 ${saved} 个${notes.length ? '，' + notes.join('、') : ''}`);

  refreshAfterUpload(target);
}

// 单个文件直传：请求体就是文件本身，不套 multipart。
// 大视频套 multipart 的话手机端磁盘上会同时存在两份（收到的请求体、
// 从里面拆出来的那一段），8GB 的片子要占 16GB。
function sendFile(file, folderId, onProgress){
  return new Promise((resolve, reject) => {
    const name = file.relPath || file.webkitRelativePath || file.name;
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/upload-file?folder=' + folderId + '&name=' + encodeURIComponent(name));
    xhr.setRequestHeader('Content-Type', 'application/octet-stream');
    xhr.upload.onprogress = e => { if(e.lengthComputable) onProgress(e.loaded); };
    xhr.onload = () => {
      try{ resolve(JSON.parse(xhr.responseText)); }
      catch(err){ reject(err); }
    };
    xhr.onerror = () => reject(new Error('network'));
    xhr.send(file);
  });
}

function sendBatch(files, folderId, onProgress){
  return new Promise((resolve, reject) => {
    const form = new FormData();
    // 把相对路径当文件名发过去，手机端照着逐级建目录
    files.forEach(f => form.append('files', f, f.relPath || f.webkitRelativePath || f.name));

    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/upload?folder=' + folderId);
    xhr.upload.onprogress = e => { if(e.lengthComputable) onProgress(e.loaded); };
    xhr.onload = () => {
      try{ resolve(JSON.parse(xhr.responseText)); }
      catch(err){ reject(err); }
    };
    xhr.onerror = () => reject(new Error('network'));
    xhr.send(form);
  });
}

function refreshAfterUpload(folderId){
  if(view.level === 'photos' && view.folderId === folderId){
    go('photos', view.groupId, view.folderId);
  }else{
    load();
  }
  fetch('/api/state', {cache:'no-store'}).then(r => r.json()).then(s => {
    state = s;
    $('#devinfo').textContent = `${s.device} · 共 ${s.totalPhotos} 张照片`;
  }).catch(() => {});
}

load();
setInterval(() => { if(view.level === 'groups' && !uploading) load(); }, 10000);
</script>
</body>
</html>
"""#
}
