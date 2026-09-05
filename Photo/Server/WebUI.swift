import Foundation

/// 网页端（局域网浏览器访问）。单页应用，纯原生 JS，无外部依赖。
enum WebUI {

    static let page: String = #"""
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>阅读器</title>
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
.wrap{max-width:900px;margin:0 auto;padding:0 20px}

header{position:sticky;top:0;z-index:20;background:var(--bg);border-bottom:1px solid var(--line)}
.hbar{display:flex;align-items:center;gap:12px;height:60px}
.logo{width:32px;height:32px;flex:none;line-height:0}
.logo svg{width:32px;height:32px;display:block}
.htitle{font-weight:700;font-size:16.5px;letter-spacing:-.2px}
.hsub{font-size:12.5px;color:var(--sub);margin-top:1px}

.btn{display:inline-flex;align-items:center;gap:7px;height:34px;padding:0 14px;
  border-radius:10px;background:var(--fill);font-weight:600;font-size:13.5px}
.btn.primary{background:var(--accent);color:#fff}
.btn:active{transform:scale(.97)}

.drop{border:2px dashed var(--line);border-radius:var(--radius);padding:34px 20px;text-align:center;
  background:var(--surface);margin:18px 0;transition:border-color .15s,background .15s}
.drop.over{border-color:var(--accent)}
.drop h3{margin:0 0 4px;font-size:15.5px}
.drop p{margin:0 0 14px;color:var(--sub);font-size:13px}

.books{display:flex;flex-direction:column;gap:10px}
.book{display:flex;align-items:center;gap:14px;background:var(--surface);
  border-radius:var(--radius);padding:14px 16px}
.spine{width:34px;height:46px;border-radius:4px 7px 7px 4px;flex:none;
  background:linear-gradient(140deg,#2E5F86,#1E4160)}
.bmain{flex:1;min-width:0}
.btitle{font-weight:650;font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.bmeta{font-size:12.5px;color:var(--sub);margin-top:2px}
.mini{height:28px;padding:0 10px;border-radius:8px;background:var(--fill);
  font-size:12.5px;font-weight:600;color:var(--sub)}
.mini.danger{color:var(--danger)}

.empty-state{text-align:center;padding:56px 20px;color:var(--sub)}
.empty-state h3{color:var(--text);margin:0 0 6px;font-size:16px}
.empty-state p{margin:0;font-size:13.5px}

#uploading{position:fixed;left:50%;bottom:26px;transform:translateX(-50%);z-index:90;
  min-width:280px;max-width:88vw;background:var(--surface);border:1px solid var(--line);
  border-radius:16px;padding:13px 16px;display:none}
#uploading.on{display:block}
#uploading .urow{display:flex;align-items:center;gap:10px;font-size:13.5px;font-weight:600}
#uploading .upct{margin-left:auto;color:var(--sub);font-variant-numeric:tabular-nums}
#uploading .ub{height:6px;border-radius:3px;background:var(--fill);overflow:hidden;margin-top:9px}
#uploading .ub i{display:block;height:100%;width:0;background:var(--accent);transition:width .15s}

#toast{position:fixed;left:50%;bottom:96px;transform:translateX(-50%) translateY(10px);
  background:#12141A;color:#fff;padding:10px 18px;border-radius:12px;font-size:13.5px;
  opacity:0;pointer-events:none;transition:opacity .2s,transform .2s;z-index:95}
#toast.on{opacity:1;transform:translateX(-50%) translateY(0)}
</style>
</head>
<body>

<header><div class="wrap"><div class="hbar">
  <div class="logo" id="logo"></div>
  <div>
    <div class="htitle">书架</div>
    <div class="hsub" id="devinfo">连接中…</div>
  </div>
</div></div></header>

<div class="wrap">
  <div class="drop" id="drop">
    <h3>把小说拖到这里</h3>
    <p>支持 TXT 和 EPUB，可以一次拖多本</p>
    <button class="btn primary" onclick="pick()">选择文件</button>
  </div>
  <div id="main"></div>
</div>

<div id="uploading">
  <div class="urow"><span id="ustat">上传中</span><span class="upct" id="upct">0%</span></div>
  <div class="ub"><i id="ufill"></i></div>
</div>
<div id="toast"></div>

<script>
const $ = s => document.querySelector(s);
let books = [];

// 和 App 图标同一本书。路径是按图标那套归一化坐标 ×64 算出来的，
// 圆角、厚度、行距、书签带的位置都对得上。
function logoSVG(){
  return '<svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg"><clipPath id="card"><rect width="64" height="64" rx="15"/></clipPath><g clip-path="url(#card)"><rect width="64" height="64" fill="#E8F3EA"/><ellipse cx="26.56" cy="67.84" rx="40.64" ry="25.6" fill="#569E5C"/><ellipse cx="39.36" cy="74.56" rx="42.56" ry="27.2" fill="#6CB370"/><g fill="#FAC94A"><path d="M11.39 8.96L12.09 10.95L14.08 11.65L12.09 12.35L11.39 14.34L10.69 12.35L8.7 11.65L10.69 10.95Z"/><path d="M53.89 8.32L54.35 9.65L55.68 10.11L54.35 10.58L53.89 11.9L53.42 10.58L52.1 10.11L53.42 9.65Z"/></g><path d="M35.07 35.84H38.66V54.14L36.86 51.71Z" fill="#E25C4C"/><path d="M35.07 35.84V54.14L36.86 51.71Z" fill="#E25C4C"/><path d="M37.5 35.84H38.66V54.14L37.5 52.48Z" fill="#C44437"/><path d="M30.85 23.04Q16.96 18.05 9.6 18.88Q6.4 18.69 6.4 21.89L6.4 39.68Q6.4 42.88 9.6 42.62Q16.96 48.9 30.85 48.51Z" fill="#2C5C84"/><path d="M33.15 23.04Q47.04 18.05 54.4 18.88Q57.6 18.69 57.6 21.89L57.6 39.68Q57.6 42.88 54.4 42.62Q47.04 48.9 33.15 48.51Z" fill="#2C5C84"/><path d="M30.85 22.02Q16.96 17.02 9.6 17.86Q6.4 17.66 6.4 20.86L6.4 38.66Q6.4 41.86 9.6 41.6Q16.96 47.87 30.85 47.49Z" fill="#DBCDB5"/><path d="M33.15 22.02Q47.04 17.02 54.4 17.86Q57.6 17.66 57.6 20.86L57.6 38.66Q57.6 41.86 54.4 41.6Q47.04 47.87 33.15 47.49Z" fill="#DBCDB5"/><path d="M30.85 21.18Q16.96 16.19 9.6 17.02Q6.4 16.83 6.4 20.03L6.4 37.82Q6.4 41.02 9.6 40.77Q16.96 47.04 30.85 46.66Z" fill="#EEE5D4"/><path d="M33.15 21.18Q47.04 16.19 54.4 17.02Q57.6 16.83 57.6 20.03L57.6 37.82Q57.6 41.02 54.4 40.77Q47.04 47.04 33.15 46.66Z" fill="#EEE5D4"/><path d="M30.85 20.35Q16.96 15.36 9.6 16.19Q6.4 16.0 6.4 19.2L6.4 36.99Q6.4 40.19 9.6 39.94Q16.96 46.21 30.85 45.82Z" fill="#FFFDF7"/><path d="M33.15 20.35Q47.04 15.36 54.4 16.19Q57.6 16.0 57.6 19.2L57.6 36.99Q57.6 40.19 54.4 39.94Q47.04 46.21 33.15 45.82Z" fill="#FFFDF7"/><g stroke="#C6D4E2" stroke-width="1.28" stroke-linecap="round"><path d="M11.52 22.53L26.75 27.01"/><path d="M11.52 27.01L26.75 31.49"/><path d="M11.52 31.49L26.75 35.97"/><path d="M16.32 37.22L26.75 40.45"/><path d="M52.48 22.53L37.25 27.01"/><path d="M52.48 27.01L37.25 31.49"/><path d="M52.48 31.49L37.25 35.97"/><path d="M47.68 37.22L37.25 40.45"/></g><path d="M31.36 20.35H32.64L33.22 48.51H30.78Z" fill="#2C5C84"/></g></svg>';
}

$('#logo').innerHTML = logoSVG();

function esc(s){
  return String(s).replace(/[&<>"']/g, c =>
    ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}

function toast(text){
  const t = $('#toast');
  t.textContent = text;
  t.classList.add('on');
  clearTimeout(t._timer);
  t._timer = setTimeout(() => t.classList.remove('on'), 2000);
}

async function load(){
  try{
    const [state, list] = await Promise.all([
      fetch('/api/state', {cache:'no-store'}).then(r => r.json()),
      fetch('/api/books', {cache:'no-store'}).then(r => r.json())
    ]);
    $('#devinfo').textContent = state.device + ' · 共 ' + state.totalBooks + ' 本';
    books = list.books || [];
    render();
  }catch(e){
    $('#devinfo').textContent = '连接断开，请确认手机端仍开着传输页面';
  }
}

function render(){
  const main = $('#main');
  if(!books.length){
    main.innerHTML = '<div class="empty-state"><h3>书架是空的</h3>'
                   + '<p>把 TXT 或 EPUB 拖进上面的方框</p></div>';
    return;
  }
  main.innerHTML = '<div class="books">' + books.map(b =>
      '<div class="book">'
    + '<div class="spine"></div>'
    + '<div class="bmain">'
    + '<div class="btitle">' + esc(b.title) + '</div>'
    + '<div class="bmeta">' + esc(b.author || '未知作者') + ' · ' + esc(b.format)
    + ' · ' + b.chapters + ' 章 · ' + esc(b.progress) + '</div>'
    + '</div>'
    + '<button class="mini danger" onclick="removeBook(\'' + b.id + '\')">删除</button>'
    + '</div>').join('') + '</div>';
}

async function removeBook(id){
  if(!confirm('删除这本书？阅读进度也会一起删掉。')) return;
  await fetch('/api/book/delete', {
    method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify({id})
  });
  toast('已删除');
  load();
}

/* ---------- 上传 ---------- */
const BOOK_EXT = /\.(txt|epub)$/i;

const picker = document.createElement('input');
picker.type = 'file';
picker.multiple = true;
picker.accept = '.txt,.epub';
picker.onchange = () => { if(picker.files.length) upload(picker.files); picker.value = ''; };
function pick(){ picker.click(); }

function showProgress(text, ratio){
  $('#uploading').classList.add('on');
  $('#ustat').textContent = text;
  const pct = Math.min(100, Math.round(ratio * 100));
  $('#upct').textContent = pct + '%';
  $('#ufill').style.width = pct + '%';
}
function hideProgress(){ setTimeout(() => $('#uploading').classList.remove('on'), 600); }

let uploading = false;

async function upload(fileList){
  const all = [...fileList].filter(f => BOOK_EXT.test(f.name));
  const ignored = fileList.length - all.length;
  if(!all.length){ toast('只支持 TXT 和 EPUB'); return; }
  if(uploading){ toast('还有一本正在上传，请稍候'); return; }

  uploading = true;
  let saved = 0, failed = 0;
  // 一本一本传：手机端要分章，几本一起上去会卡住
  for(let i = 0; i < all.length; i++){
    try{
      const res = await send(all[i], loaded =>
        showProgress('上传中 ' + saved + ' / ' + all.length,
                     (i + loaded / all[i].size) / all.length));
      if(res && res.ok) saved += 1; else failed++;
    }catch(e){ failed++; }
  }
  uploading = false;
  hideProgress();

  const notes = [];
  if(ignored) notes.push(ignored + ' 个格式不支持');
  if(failed) notes.push(failed + ' 本失败');
  toast('已导入 ' + saved + ' 本' + (notes.length ? '，' + notes.join('、') : ''));
  load();
}

function send(file, onProgress){
  return new Promise((resolve, reject) => {
    const form = new FormData();
    form.append('file', file, file.name);
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/api/book/upload');
    xhr.upload.onprogress = e => { if(e.lengthComputable) onProgress(e.loaded); };
    xhr.onload = () => { try{ resolve(JSON.parse(xhr.responseText)); }catch(err){ reject(err); } };
    xhr.onerror = () => reject(new Error('network'));
    xhr.send(form);
  });
}

/* ---------- 拖放 ---------- */
const drop = $('#drop');
['dragenter','dragover'].forEach(ev => drop.addEventListener(ev, e => {
  e.preventDefault(); drop.classList.add('over');
}));
['dragleave','drop'].forEach(ev => drop.addEventListener(ev, e => {
  e.preventDefault(); drop.classList.remove('over');
}));
// 整页都能接住，不用非得拖准那个方框
window.addEventListener('dragover', e => e.preventDefault());
window.addEventListener('drop', e => {
  e.preventDefault();
  if(e.dataTransfer.files.length) upload(e.dataTransfer.files);
});

load();
setInterval(() => { if(!uploading) load(); }, 10000);
</script>
</body>
</html>
"""#
}
