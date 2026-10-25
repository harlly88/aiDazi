/// 19.6 / 第二十章 / 第二十一章 / 第二十三章：局域网配置网页（内嵌 HTML 常量，不落盘、零 CDN）
///
/// - 浅蓝主色调与 App 一致，卡片式简约风格，手机/电脑浏览器自适应
/// - 四张能力卡片统一为**三要素结构**（21.1）：API Key + 接口地址 + 模型名称，
///   每项可指向独立的大模型服务（自建网关/中转），三要素配套生效
/// - LLM 卡无 provider 下拉（21.1）：三要素作用于当前 provider，说明文字显示
///   「当前厂商」，切换厂商在 App 设置内完成
/// - **第二十三章：一次性统一保存**——四卡片各自填写完成后，点底部「保存全部
///   配置」按钮合并提交（密钥非空、地址/模型名与初始值不同才携带该字段）；
///   任一项保存成功 → 服务自动关闭 → 禁用全部控件
/// - 密钥掩码预填（网页永远拿不到明文）；地址/模型名明文回显预填；
///   空地址 = 官方默认，空模型名 = 默认模型
/// - 卡片⑤ 导入角色保持独立（不参与统一保存，导入后服务保持开启可连续导入）
/// - 第十六章：tip 条「恢复千问默认设定」按钮——confirm 二次警告清除全部密钥
///   → POST /api/reset → 重新拉取 /api/status 刷新掩码/预填/基准（不关服务）
/// - 全部 fetch + JSON，禁用原生表单提交（避免页面跳转）
const String lanConfigHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI搭子 · 配置中心</title>
<style>
:root{--blue:#1B6FD8;--bg:#F0F6FF;--text:#1a2b3c;--muted:#7a92a8;}
*{box-sizing:border-box;}
body{font-family:system-ui,-apple-system,'Segoe UI',Roboto,'PingFang SC','Microsoft YaHei',sans-serif;background:var(--bg);margin:0;padding:16px;color:var(--text);}
.wrap{max-width:560px;margin:0 auto;}
h1{font-size:22px;color:var(--blue);margin:8px 0 4px;}
.sub{font-size:13px;color:var(--muted);margin:0 0 20px;}
.card{background:#fff;border-radius:12px;padding:16px;margin-bottom:14px;box-shadow:0 1px 4px rgba(27,111,216,.08);}
.card h2{font-size:16px;margin:0 0 4px;color:var(--blue);}
.desc{font-size:12px;color:var(--muted);margin:0 0 10px;}
input[type=password],input[type=text],select{width:100%;padding:10px;border:1px solid #cfe0f5;border-radius:8px;font-size:14px;margin-bottom:8px;background:#fbfdff;}
.row{display:flex;gap:8px;align-items:center;}
.row input{flex:1;margin-bottom:0;}
button{background:var(--blue);color:#fff;border:none;border-radius:8px;padding:10px 18px;font-size:14px;cursor:pointer;}
button.ghost{background:#fff;color:var(--blue);border:1px solid var(--blue);padding:9px 12px;}
button.saveAll{width:100%;padding:14px;font-size:16px;font-weight:600;}
button:disabled{opacity:.45;cursor:not-allowed;}
.msg{font-size:13px;margin-top:8px;min-height:18px;word-break:break-all;}
.ok{color:#1a9c5c}.warn{color:#c98a1a}.err{color:#d9534f}
.mask{font-size:12px;color:var(--muted);margin:-2px 0 8px;}
input[type=file]{font-size:13px;margin-bottom:8px;width:100%;}
#done{display:none;background:#E8F7EF;border:1px solid #1a9c5c;color:#12724a;border-radius:10px;padding:14px;font-size:14px;margin-bottom:14px;}
.tip{background:#EAF3FE;border:1px solid #cfe0f5;color:#1b6dd8;border-radius:10px;padding:12px 14px;font-size:13px;margin-bottom:14px;line-height:1.7;}
.tip a{color:var(--blue);font-weight:600;word-break:break-all;}
.tip .ghost{font-size:12px;padding:5px 10px;margin-left:6px;}
</style>
</head>
<body>
<div class="wrap">
<h1>AI搭子 · 配置中心</h1>
<p class="sub">请确保电脑与手机连接同一 WiFi；各卡片填写完成后，点底部「保存全部配置」一次性提交</p>
<div class="tip">建议申请<b>阿里云百炼千问 API Key</b>——一个 Key 通用全部功能（文字对话 / 语音 / 图像 / 视频），四个卡片填同一个即可。<a href="https://bailian.console.aliyun.com/?apiKey=1#!/api-key" target="_blank" rel="noopener">点此申请千问 API Key ↗</a><button class="ghost" type="button" onclick="resetDefaults()">恢复千问默认设定</button><div class="msg" id="resetMsg"></div></div>
<div id="done">已保存，配置服务已关闭，可关闭本页</div>

<div class="card">
<h2>① 文字（LLM 对话）</h2>
<p class="desc" id="llmDesc">每项三要素配套：API Key + 接口地址 + 模型名称，可指向任意 OpenAI 兼容服务</p>
<div class="mask" id="llmMask">密钥：未配置</div>
<div class="row">
<input type="password" id="llmKey" placeholder="粘贴 API Key" autocomplete="off">
<button class="ghost" onclick="toggle('llmKey',this)">显示</button>
</div>
<input type="text" id="llmUrl" placeholder="接口地址（OpenAI 兼容 base URL）">
<input type="text" id="llmModel" placeholder="模型名称 如 qwen3.7-flash">
</div>

<div class="card">
<h2>② 语音（TTS）</h2>
<p class="desc">三要素配套：密钥 + 接口地址 + 模型名称；可指向独立服务，留空恢复官方默认</p>
<div class="mask" id="ttsMask">密钥：未配置</div>
<div class="row">
<input type="password" id="ttsKey" placeholder="粘贴 API Key" autocomplete="off">
<button class="ghost" onclick="toggle('ttsKey',this)">显示</button>
</div>
<input type="text" id="ttsUrl" placeholder="接口地址 https://dashscope.aliyuncs.com">
<input type="text" id="ttsModel" placeholder="模型名称 如 cosyvoice-v3-flash">
</div>

<div class="card">
<h2>③ 图像</h2>
<p class="desc">三要素配套：密钥 + 接口地址 + 模型名称；可指向独立服务，留空恢复官方默认</p>
<div class="mask" id="imageMask">密钥：未配置</div>
<div class="row">
<input type="password" id="imageKey" placeholder="粘贴 API Key" autocomplete="off">
<button class="ghost" onclick="toggle('imageKey',this)">显示</button>
</div>
<input type="text" id="imageUrl" placeholder="接口地址 https://dashscope.aliyuncs.com">
<input type="text" id="imageModel" placeholder="模型名称 如 wan2.7-image">
</div>

<div class="card">
<h2>④ 视频</h2>
<p class="desc">三要素配套：密钥 + 接口地址 + 模型名称；可指向独立服务，留空恢复官方默认</p>
<div class="mask" id="videoMask">密钥：未配置</div>
<div class="row">
<input type="password" id="videoKey" placeholder="粘贴 API Key" autocomplete="off">
<button class="ghost" onclick="toggle('videoKey',this)">显示</button>
</div>
<input type="text" id="videoUrl" placeholder="接口地址 https://dashscope.aliyuncs.com">
<input type="text" id="videoModel" placeholder="模型名称 如 wan3.0-video-prime">
</div>

<button class="saveAll" onclick="saveAll()">保存全部配置</button>
<div class="msg" id="allMsg"></div>

<div class="card">
<h2>⑤ 导入角色</h2>
<p class="desc">支持 SillyTavern V2 角色卡（.png / .json），单张上限 50MB；导入后可继续上传下一张</p>
<input type="file" id="charFile" accept=".png,.json">
<div class="row">
<button onclick="uploadChar()">上传</button>
<a href="__CHARACTER_GEN_URL__" target="_blank" rel="noopener"><button class="ghost" type="button">角色辅助生成</button></a>
</div>
<div class="msg" id="charMsg"></div>
</div>

<div class="card">
<h2>⑥ 导出角色</h2>
<p class="desc">下载角色池中的角色为标准角色卡（PNG，含音色 / 参考图 / 背景图 / 性格数据）；导出为读操作，服务保持开启</p>
<div id="charList" style="font-size:13px;color:#7a92a8">加载中…</div>
</div>

<div class="card">
<h2>⑦ 导入故事</h2>
<p class="desc">两种方式：文件导入 / 直接输入标题与内容；导入后可继续下一个</p>
<div class="row" style="margin-bottom:8px">
<button class="ghost" id="storyModeFileBtn" type="button" onclick="toggleStoryMode('file')">文件导入</button>
<button class="ghost" id="storyModeTextBtn" type="button" onclick="toggleStoryMode('text')">直接输入</button>
</div>
<div id="storyFileBox">
<input type="file" id="storyFile" accept=".json,application/json">
</div>
<div id="storyTextBox" style="display:none">
<input type="text" id="storyTitle" placeholder="故事标题（如：校园恋爱物语）" style="width:100%;padding:10px;border:1px solid #cfe0f5;border-radius:8px;font-size:14px;margin-bottom:8px;background:#fbfdff;">
<textarea id="storyContent" rows="6" placeholder="故事背景内容（整段文本，将作为一条故事背景导入）…" style="width:100%;padding:10px;border:1px solid #cfe0f5;border-radius:8px;font-size:13px;margin-bottom:8px;resize:vertical;background:#fbfdff;"></textarea>
</div>
<button onclick="uploadStory()">导入故事</button>
<div class="msg" id="storyImportMsg"></div>
</div>

<div class="card">
<h2>⑧ 导出故事</h2>
<p class="desc">下载故事池中的故事为 JSON（characterBook 格式）；导出为读操作，服务保持开启</p>
<div id="storyList" style="font-size:13px;color:#7a92a8">加载中…</div>
</div>
</div>
<script>
function $(id){return document.getElementById(id);}
function toggle(id,btn){var e=$(id);if(e.type==='password'){e.type='text';btn.textContent='隐藏';}else{e.type='password';btn.textContent='显示';}}
function setMsg(id,text,cls){var m=$(id);m.textContent=text;m.className='msg '+(cls||'');}
function disableAll(){var els=document.querySelectorAll('button,input,select');for(var i=0;i<els.length;i++){els[i].disabled=true;}}

// 第二十一章：各卡片地址/模型名初始值（判断「是否有变化」的基准）
var init={llm:{url:'',model:''},tts:{url:'',model:''},image:{url:'',model:''},video:{url:'',model:''}};

// 第十六章：加载/刷新状态（页面加载与「恢复默认」后复用）
function loadStatus(){
fetch('/api/status').then(function(r){return r.json();}).then(function(s){
  if(!s||!s.ok)return;
  // 密钥占位符先归位（重置后掩码为「未配置」时回落默认提示，避免残留旧掩码）
  $('llmKey').placeholder='粘贴 API Key';
  $('ttsKey').placeholder='粘贴 API Key';
  $('imageKey').placeholder='粘贴 API Key';
  $('videoKey').placeholder='粘贴 API Key';
  if(s.llmKeyMask&&s.llmKeyMask!=='未配置'){$('llmKey').placeholder='已配置 '+s.llmKeyMask+'（留空保持不变）';}
  if(s.ttsKeyMask&&s.ttsKeyMask!=='未配置'){$('ttsKey').placeholder='已配置 '+s.ttsKeyMask+'（留空保持不变）';}
  if(s.imageKeyMask&&s.imageKeyMask!=='未配置'){$('imageKey').placeholder='已配置 '+s.imageKeyMask+'（留空保持不变）';}
  if(s.videoKeyMask&&s.videoKeyMask!=='未配置'){$('videoKey').placeholder='已配置 '+s.videoKeyMask+'（留空保持不变）';}
  $('llmMask').textContent='密钥：'+(s.llmKeyMask||'未配置');
  $('ttsMask').textContent='密钥：'+(s.ttsKeyMask||'未配置');
  $('imageMask').textContent='密钥：'+(s.imageMask||'未配置');
  $('videoMask').textContent='密钥：'+(s.videoKeyMask||'未配置');
  // 第二十一章：LLM 卡显示当前厂商（切换在 App 设置内完成）
  if(s.currentProvider){
    $('llmDesc').textContent='当前厂商：'+s.currentProvider+'；三要素配套：密钥 + 接口地址 + 模型名称，可指向任意 OpenAI 兼容服务';
  }
  // 地址 / 模型名明文预填 + 记录初始基准
  init.llm.url=s.llmUrl||'';$('llmUrl').value=init.llm.url;
  init.llm.model=s.llmModel||'';$('llmModel').value=init.llm.model;
  init.tts.url=s.ttsUrl||'';$('ttsUrl').value=init.tts.url;
  init.tts.model=s.ttsModel||'';$('ttsModel').value=init.tts.model;
  init.image.url=s.imageUrl||'';$('imageUrl').value=init.image.url;
  init.image.model=s.imageModel||'';$('imageModel').value=init.image.model;
  init.video.url=s.videoUrl||'';$('videoUrl').value=init.video.url;
  init.video.model=s.videoModel||'';$('videoModel').value=init.video.model;
}).catch(function(){});
}
loadStatus();

// 第十六章：恢复千问默认设定——confirm 二次警告 → POST /api/reset → 刷新状态（不关服务）
function resetDefaults(){
  if(!confirm('确定要恢复千问 API 默认设定吗？\n\n将清除全部已保存的 API 密钥（文字 / 语音 / 图像 / 视频），并把接口地址、模型名恢复为官方默认设定，此操作不可撤销。'))return;
  setMsg('resetMsg','恢复中…','');
  fetch('/api/reset',{method:'POST'})
   .then(function(r){return r.json();})
   .then(function(d){
     if(d&&d.ok){
       var ids=['llmKey','ttsKey','imageKey','videoKey'];
       for(var i=0;i<ids.length;i++){$(ids[i]).value='';}
       loadStatus();
       setMsg('resetMsg','已恢复默认设定：密钥已全部清除，请重新填写 API Key 后点「保存全部配置」','ok');
     }else{setMsg('resetMsg','恢复失败：'+(d&&d.error||'未知错误'),'err');}
   })
   .catch(function(e){setMsg('resetMsg','提交失败：'+e,'err');});
}

// 收集单张卡片的变更字段（无变化返回 null）
// 密钥非空才携带；LLM 地址/模型名空值忽略；三能力空 = 恢复官方默认/默认模型名
function collect(kind){
  var body={};
  var has=false;
  var key=$(kind+'Key').value.trim();
  var url=$(kind+'Url').value.trim();
  var model=$(kind+'Model').value.trim();
  var urlChanged,modelChanged;
  if(kind==='llm'){
    urlChanged=(url!==''&&url!==init.llm.url);
    modelChanged=(model!==''&&model!==init.llm.model);
  }else{
    urlChanged=(url!==init[kind].url);
    modelChanged=(model!==init[kind].model);
  }
  if(key){body[kind+'Key']=key;has=true;}
  if(urlChanged){body[kind+'Url']=url;has=true;}
  if(modelChanged){body[kind+'Model']=model;has=true;}
  return has?body:null;
}

// 第二十三章：一次性保存全部四卡片 → 一次 POST（后端任一字段保存成功即关服务）
function saveAll(){
  var body={};
  var kinds=['llm','tts','image','video'];
  for(var i=0;i<kinds.length;i++){
    var part=collect(kinds[i]);
    if(part){
      for(var k in part){body[k]=part[k];}
    }
  }
  if(!Object.keys(body).length){
    setMsg('allMsg','请至少填写或修改一项（任意卡片的密钥 / 接口地址 / 模型名称）','err');
    return;
  }
  setMsg('allMsg','提交中…','');
  fetch('/api/keys',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)})
   .then(function(r){return r.json();})
   .then(function(d){
     if(d.ok){$('done').style.display='block';disableAll();setMsg('allMsg','已保存','ok');}
     else{setMsg('allMsg','保存失败：'+(d.error||'未知错误'),'err');}
   })
   .catch(function(e){setMsg('allMsg','提交失败：'+e,'err');});
}

function uploadChar(){
  var f=$('charFile').files[0];
  if(!f){setMsg('charMsg','请先选择角色卡文件（.png / .json）','err');return;}
  if(f.size>50*1024*1024){setMsg('charMsg','文件超过 50MB 上限','err');return;}
  setMsg('charMsg','上传处理中，含音色注册时约需十几秒…','');
  fetch('/api/character?filename='+encodeURIComponent(f.name),{method:'POST',headers:{'Content-Type':'application/octet-stream'},body:f})
   .then(function(r){return r.json();})
   .then(function(d){
     if(d.ok){
       var t='已加入角色池';
       if(d.warnings&&d.warnings.length){t+='（'+d.warnings.join('；')+'）';}
       setMsg('charMsg',t,'ok');
       $('charFile').value='';
       loadCharList();
     }else{setMsg('charMsg','导入失败：'+(d.error||'未知错误'),'err');}
   })
   .catch(function(e){setMsg('charMsg','上传失败：'+e,'err');});
}

// 第二十五章：导出角色列表（GET 只读，服务不关；导入成功后刷新）
function loadCharList(){
  fetch('/api/characters')
   .then(function(r){return r.json();})
   .then(function(d){
     var box=$('charList');
     if(!d||!d.ok){box.textContent='角色列表加载失败';return;}
     if(!d.characters||!d.characters.length){box.textContent='角色池为空';return;}
     var html='';
     for(var i=0;i<d.characters.length;i++){
       var n=d.characters[i];
       html+='<div class="row" style="margin-bottom:6px">'
           +'<span style="flex:1;font-size:14px;color:var(--text);word-break:break-all">'+n+'</span>'
           +'<a href="/api/character/export?name='+encodeURIComponent(n)+'" download>'
           +'<button class="ghost" type="button">下载</button></a></div>';
     }
     box.innerHTML=html;
   })
   .catch(function(e){$('charList').textContent='角色列表加载失败';});
}
loadCharList();

// 第十五章：故事导入/导出
function loadStoryList(){
  fetch('/api/stories')
   .then(function(r){return r.json();})
   .then(function(d){
     var box=$('storyList');
     if(!d||!d.ok){box.textContent='故事列表加载失败';return;}
     if(!d.stories||!d.stories.length){box.textContent='故事池为空';return;}
     var html='';
     for(var i=0;i<d.stories.length;i++){
       var s=d.stories[i];
       var ts=s.timestamp;
       var name=s.name||'未命名';
       html+='<div class="row" style="margin-bottom:6px">'
           +'<span style="flex:1;font-size:14px;color:var(--text);word-break:break-all">'+name+'</span>'
           +'<a href="/api/story/export?timestamp='+encodeURIComponent(ts)+'" download>'
           +'<button class="ghost" type="button">下载</button></a></div>';
     }
     box.innerHTML=html;
   })
   .catch(function(e){$('storyList').textContent='故事列表加载失败';});
}
loadStoryList();

// 第十五章：导入故事模式切换（文件 / 直接输入）；选中态蓝底白字（15.5 修复蓝底蓝字不可见）
var storyMode='file';
function toggleStoryMode(m){
  storyMode=m;
  $('storyFileBox').style.display=(m==='file')?'':'none';
  $('storyTextBox').style.display=(m==='text')?'':'none';
  var btns={file:'storyModeFileBtn',text:'storyModeTextBtn'};
  for(var k in btns){
    var b=$(btns[k]);
    if(k===m){b.style.background='var(--blue)';b.style.color='#fff';}
    else{b.style.background='#fff';b.style.color='var(--blue)';}
  }
}
toggleStoryMode('file');

// 直接输入模式：标题+内容 → 组合标准 characterBook JSON（与 App 内 _editNewStory 一致：整块文本作为单条 entry）
function buildStoryJson(title,content){
  return JSON.stringify({
    name:title,
    description:'',
    extensions:{},
    entries:[{keys:[],content:content,extensions:{},enabled:true,insertion_order:0,constant:true}]
  });
}

function uploadStory(){
  if(storyMode==='file'){
    var file=$('storyFile').files[0];
    if(!file){setMsg('storyImportMsg','请选择文件','warn');return;}
    fetch('/api/story',{method:'POST',body:file})
     .then(function(r){return r.json();})
     .then(function(d){
       if(d&&d.ok){
         setMsg('storyImportMsg','导入成功','ok');
         $('storyFile').value='';
         loadStoryList();
       }else{setMsg('storyImportMsg','导入失败：'+(d&&d.error||'未知错误'),'err');}
     })
     .catch(function(e){setMsg('storyImportMsg','上传失败：'+e,'err');});
  }else{
    var title=$('storyTitle').value.trim();
    var content=$('storyContent').value.trim();
    if(!title){setMsg('storyImportMsg','请输入故事标题','warn');return;}
    if(!content){setMsg('storyImportMsg','请输入故事内容','warn');return;}
    var bytes=new TextEncoder().encode(buildStoryJson(title,content));
    fetch('/api/story',{method:'POST',body:bytes,headers:{'Content-Type':'application/json'}})
     .then(function(r){return r.json();})
     .then(function(d){
       if(d&&d.ok){
         setMsg('storyImportMsg','导入成功','ok');
         $('storyTitle').value='';
         $('storyContent').value='';
         loadStoryList();
       }else{setMsg('storyImportMsg','导入失败：'+(d&&d.error||'未知错误'),'err');}
     })
     .catch(function(e){setMsg('storyImportMsg','上传失败：'+e,'err');});
  }
}
</script>
</body>
</html>''';
