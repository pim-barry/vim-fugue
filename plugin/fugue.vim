command! Browse echo "Hello4"
command! -bang -nargs=? Fugue call s:OpenFugueCommand(<bang>0, <q-mods>, <q-args>)
command! DFugue call s:DebugFugueCommand()

augroup fugue
  autocmd!
  autocmd WinResized * call s:UpdateFugueOverlay()
  autocmd VimResized * call s:UpdateFugueOverlay()
  autocmd VimResized * call s:OnVimResized()
  autocmd User WinNr call s:UpdateFugueOverlay()
  "autocmd FocusLost * call s:OnFocusLost()
  "autocmd FocusGained * call  s:OnTabEnter()
  autocmd TabEnter * call s:OnTabEnter()
  autocmd TabNew * call s:OnTabNew()
  autocmd TabClosed * call s:OnTabClosed()
  autocmd VimLeavePre * call s:StopBroz()
augroup END

let s:fugue_winid = -1
let s:macvim_cell_pad_top = 1
let s:macvim_cell_pad_left = 2
let s:fullscreen_gutter_top = 39
let s:fullscreen_gutter_left = 2
let s:broz_job = v:null
let s:broz_bufnr = -1
let s:last_payload = {}
let s:broz_url = 'https://pornhub.com'
let s:state_timer = -1
let s:bounds_timer = -1
let s:focus_timer = -1
let s:last_window_metrics = {}
let s:last_cell_pixels = []
let s:broz_hidden = 0
let s:last_winpos = []
let s:log_path = expand('~/Desktop/log.txt')
let s:vim_window_id = ''
let s:initial_geometry_timer = -1

let s:script_dir = fnamemodify(expand('<sfile>:p:h'), ':p')
let s:broz_path = substitute(fnamemodify(s:script_dir . '/../broz', ':p'), '/$', '', '')
if empty($PATH)
  let $PATH = s:broz_path
else
  let s:path_entries = map(split($PATH, ':'), 'substitute(v:val, "/$", "", "")')
  if index(s:path_entries, s:broz_path) < 0
    let $PATH = s:broz_path . ':' . $PATH
  endif
  unlet s:path_entries
endif

function! s:OpenFugueOverlay(...) abort
  if !has('terminal') || !exists('*term_start')
    call s:LogDebug('[fugue] :terminal not supported in this Vim build')
    call s:LogDebug('[fugue] missing keys in payload')
    return
  endif
  call s:StopBroz()
  let s:fugue_winid = win_getid()
  let s:broz_hidden = 0
  let s:last_payload = {}
  let cmd = ['broz.js', '--top']
  call s:GetYabaiWindowId()
  let url = (a:0 && type(a:1) == v:t_string) ? trim(a:1) : ''
  let target_url = empty(url) ? s:broz_url : url
  let s:broz_url = target_url
  call add(cmd, target_url)
  let opts = {
        \ 'curwin': 1,
        \ 'term_kill': 'term',
        \ 'term_name': 'Fugue Broz',
        \ 'exit_cb': function('s:OnBrozExit'),
        \ }
  let term_bufnr = term_start(cmd, opts)
  if term_bufnr <= 0
    call s:LogDebug('[fugue] failed to start broz.js')
    return
  endif
  let s:broz_bufnr = term_bufnr
  let g:broz_bufnr = term_bufnr
  let term_job = term_getjob(term_bufnr)
  if term_job is v:null || type(term_job) != v:t_job
    call s:LogDebug('[fugue] failed to obtain broz job handle')
    call s:StopBroz()
    return
  endif
  let s:broz_job = term_job
  call s:LogDebug('[fugue] broz job active buffer=' . s:broz_bufnr)
  let overlay_enabled = get(g:, 'fugue_enable_overlay', 0)
  let fullscreen_mode = exists('g:macvim_fullscreen') && get(g:, 'macvim_fullscreen', 0)
  let simple_mode = !overlay_enabled || fullscreen_mode || get(g:, 'fugue_force_simple_launch', 0)
  if simple_mode
    call s:LogDebug('[fugue] simple launch: skipping overlay setup and leaving Broz visible')
    return
  endif
  call s:HideBrozOverlay()
  if exists('*term_setapi')
    call term_setapi(s:broz_bufnr, 'FugueApi_')
  endif
  if exists('*timer_start')
    call s:TriggerUpdate(0)
    call s:StartStateWatcher()
  endif
  call s:InitializeBrozGeometry()
endfunction

function! s:OpenFugueCommand(use_current, mods, url) abort
  let mods = type(a:mods) == v:t_string ? trim(a:mods) : ''
  let url = type(a:url) == v:t_string ? trim(a:url) : ''
  if !empty(url) && s:BrozIsActive()
    call s:SetBrozUrl(url)
    return
  endif
  if a:use_current
    if !empty(mods)
      call s:LogDebug('[fugue] ignoring modifiers for :Fugue! (current window)')
    endif
  else
    let split_cmd = empty(mods) ? 'vertical new' : mods . ' new'
    execute split_cmd
  endif
  if empty(url)
    call s:OpenFugueOverlay()
  else
    call s:OpenFugueOverlay(url)
  endif
endfunction

function! s:UpdateFugueOverlay() abort
  call s:TriggerUpdate(0)
endfunction

function! s:GatherGeometry() abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    call s:LogDebug('[fugue] invalid window id ' . s:fugue_winid)
    return {}
  endif
  let info = getwininfo(s:fugue_winid)
  if empty(info)
    call s:LogDebug('[fugue] getwininfo empty')
    return {}
  endif
  let w = info[0]
  let cell_px = getcellpixels()
  if empty(cell_px)
    call s:LogDebug('[fugue] getcellpixels empty')
    return {}
  endif
  let cell_w = s:ToInt(cell_px[0])
  let cell_h = s:ToInt(cell_px[1])
  if cell_w <= 0 || cell_h <= 0
    call s:LogDebug('[fugue] invalid cell size ' . string([cell_w, cell_h]))
    return {}
  endif
  let payload = {
        \ 'winid': s:fugue_winid,
        \ 'topCell': w.winrow,
        \ 'leftCell': w.wincol,
        \ 'widthCells': w.width,
        \ 'heightCells': w.height,
        \ 'cellWidthPx': cell_w,
        \ 'cellHeightPx': cell_h,
        \ }
  let payload.widthPx = s:ToInt(w.width * cell_w)
  let payload.heightPx = s:ToInt(w.height * cell_h)
  let pad_top = s:fullscreen_gutter_top
  let pad_left = s:fullscreen_gutter_left
  let payload.titlebarHeightPx = 0
  let payload.cellPadPx = {'top': pad_top, 'left': pad_left}
  let payload.topPxWin = s:ToInt(pad_top + (w.winrow - 1) * cell_h)
  let payload.leftPxWin = s:ToInt(pad_left + (w.wincol - 1) * cell_w)
  return payload
endfunction

function! s:InitializeBrozGeometry() abort
  call s:CancelInitialGeometryTimer()
  if !s:BrozIsActive()
    call s:LogDebug('[fugue] init geometry skipped: broz inactive')
    return
  endif
  let payload = s:GatherGeometry()
  if empty(payload)
    call s:LogDebug('[fugue] init geometry payload empty, using fallback')
    let payload = s:DefaultGeometryPayload()
  endif
  let s:last_payload = copy(payload)
  call s:LogDebug('[fugue] init geometry payload ' . json_encode(payload))
  call s:SafeResizeBroz(payload)
  if s:broz_hidden
    call s:ShowBrozOverlay()
  endif
endfunction

function! s:DefaultGeometryPayload() abort
  let cell_px = getcellpixels()
  let cell_w = empty(cell_px) ? 8 : s:ToInt(cell_px[0])
  let cell_h = empty(cell_px) ? 15 : s:ToInt(cell_px[1])
  let width_cells = &columns
  let height_cells = &lines - 2
  let payload = {
        \ 'winid': win_getid(),
        \ 'topCell': 1,
        \ 'leftCell': 1,
        \ 'widthCells': width_cells,
        \ 'heightCells': height_cells,
        \ 'cellWidthPx': cell_w,
        \ 'cellHeightPx': cell_h,
        \ }
  let payload.widthPx = s:ToInt(width_cells * cell_w)
  let payload.heightPx = s:ToInt(height_cells * cell_h)
  let payload.titlebarHeightPx = 0
  let payload.cellPadPx = {'top': s:fullscreen_gutter_top, 'left': s:fullscreen_gutter_left}
  let payload.topPxWin = s:fullscreen_gutter_top
  let payload.leftPxWin = s:fullscreen_gutter_left
  return payload
endfunction

function! s:ScheduleInitialGeometryRetry() abort
  if !exists('*timer_start')
    call s:InitializeBrozGeometry()
    return
  endif
  call s:CancelInitialGeometryTimer()
  let s:initial_geometry_timer = timer_start(200, {-> s:InitializeBrozGeometry()})
endfunction

function! s:CancelInitialGeometryTimer() abort
  if s:initial_geometry_timer != -1
    call timer_stop(s:initial_geometry_timer)
    let s:initial_geometry_timer = -1
  endif
endfunction

function! s:SendToBroz(payload) abort
  if !has('channel')
    call s:LogDebug('[fugue] channels not supported in this Vim build')
    return
  endif
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    call s:LogDebug('[fugue] missing broz job handle')
    return
  endif
  try
    if job_status(s:broz_job) !=# 'run'
      return
    endif
  catch /^Vim\%((\a\+)\)\=:E\d\+/
    call s:LogDebug('[fugue] job_status failed, clearing job handle')
    let s:broz_job = v:null
    return
  endtry
  if s:broz_bufnr == -1 || !bufexists(s:broz_bufnr)
    call s:LogDebug('[fugue] terminal buffer missing')
    return
  endif
  let term_channel = job_getchannel(s:broz_job)
  if term_channel is v:null || type(term_channel) != v:t_channel
    call s:LogDebug('[fugue] failed to obtain terminal channel')
    return
  endif
  let request = {}
  if has_key(a:payload, 'action')
    let request.action = a:payload.action
  endif
  if has_key(a:payload, 'widthPx') && has_key(a:payload, 'heightPx')
        \ && has_key(a:payload, 'topPxWin') && has_key(a:payload, 'leftPxWin')
    let request.width = s:ToInt(a:payload.widthPx)
    let request.height = s:ToInt(a:payload.heightPx)
    let request.x = s:ToInt(a:payload.leftPxWin)
    let request.y = s:ToInt(a:payload.topPxWin)
  endif
  if !has_key(request, 'action') && !has_key(request, 'width')
    return
  endif
  let message = json_encode(request) . "\n"
  call s:LogDebug('[fugue] send ' . message)
  call ch_sendraw(term_channel, message)
endfunction

function! s:PayloadHasGeometry(payload) abort
  return has_key(a:payload, 'widthPx') && has_key(a:payload, 'heightPx')
        \ && has_key(a:payload, 'topPxWin') && has_key(a:payload, 'leftPxWin')
endfunction

function! s:SafeResizeBroz(payload) abort
  if empty(a:payload)
    return
  endif
  if !s:PayloadHasGeometry(a:payload)
    call s:SendToBroz(a:payload)
    return
  endif
  let was_hidden = s:broz_hidden
  if !was_hidden
    call s:SendToBroz({'action': 'hide'})
  endif
  call s:SendToBroz(a:payload)
  if !was_hidden
    call s:SendToBroz({'action': 'show_inactive'})
  endif
endfunction

function! s:BrozIsActive() abort
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    return 0
  endif
  try
    return job_status(s:broz_job) ==# 'run'
  catch /^Vim\%((\a\+)\)\=:E\d\+/
    return 0
  endtry
endfunction

function! s:SetBrozUrl(url) abort
  if empty(a:url) || !has('channel')
    return
  endif
  if !s:BrozIsActive()
    return
  endif
  let channel = job_getchannel(s:broz_job)
  if channel is v:null || type(channel) != v:t_channel
    return
  endif
  let s:broz_url = a:url
  let message = json_encode({'url': a:url}) . "\n"
  call s:LogDebug('[fugue] send url ' . a:url)
  call ch_sendraw(channel, message)
  call s:TriggerUpdate(0)
endfunction


function! s:HideBrozOverlay() abort
  if !s:BrozIsActive()
    call s:LogDebug('⚠️ hide skipped: broz inactive')
    return
  endif
  if s:broz_hidden
    call s:LogDebug('⚠️ hide skipped: broz already hidden')
    return
  endif
  call s:SendToBroz({'action': 'hide'})
  let s:broz_hidden = 1
endfunction

function! s:BlurBrozOverlay() abort
  if !s:BrozIsActive()
    call s:LogDebug('⚠️ blur skipped: broz inactive')
    return
  endif
  call s:SendToBroz({'action': 'blur'})
endfunction

function! s:ShowBrozOverlay() abort
  if !s:BrozIsActive()
    call s:LogDebug('⚠️ show skipped: broz inactive')
    return
  endif
  if !s:broz_hidden
    call s:LogDebug('⚠️ show skipped: broz already visible')
    return
  endif
  let payload = empty(s:last_payload) ? s:GatherGeometry() : copy(s:last_payload)
  if empty(payload)
    call s:LogDebug('⚠️ show skipped: payload empty')
    return
  endif
  let s:last_payload = copy(payload)
  let payload.action = 'show_inactive'
  call s:SendToBroz(payload)
  let s:broz_hidden = 0
endfunction

function! s:ScheduleFocusCheck() abort
  if !exists('*timer_start')
    call s:HandleFocusCheck()
    return
  endif
  if s:focus_timer != -1
    call timer_stop(s:focus_timer)
  endif
  let s:focus_timer = timer_start(100, {-> s:HandleFocusCheck()})
endfunction

function! s:HandleFocusCheck() abort
  let s:focus_timer = -1
  if !s:BrozIsActive()
    call s:LogDebug('⚠️ focus check skipped: broz inactive')
    return
  endif
  let fugue_tab = s:GetFugueTabnr()
  if fugue_tab == -1
    call s:LogDebug('⚠️ focus check: fugue tab missing')
    call s:HideBrozOverlay()
    return
  endif
  if tabpagenr() == fugue_tab
    call s:LogDebug('focus check: showing overlay for tab ' . fugue_tab)
    call s:ShowBrozOverlay()
  else
    call s:LogDebug('focus check: current tab ' . tabpagenr() . ' != fugue tab ' . fugue_tab)
  endif
endfunction

function! s:OnFocusLost() abort
  call s:LogDebug('FocusLost event')
  if s:focus_timer != -1
    call timer_stop(s:focus_timer)
    let s:focus_timer = -1
  endif
  call s:BlurBrozOverlay()
  if get(g:, 'fugue_hide_on_focus_lost', 0)
    call s:HideBrozOverlay()
  endif
endfunction

function! s:OnFocusGained() abort
  call s:LogDebug('FocusGained event')
  call s:ScheduleFocusCheck()
  execute 'doautocmd <nomodeline> fugue TabEnter'
endfunction

function! s:OnTabEnter() abort
  if !s:BrozIsActive()
    return
  endif
  call s:LogDebug('TabEnter event tab=' . tabpagenr())
  let fugue_tab = s:GetFugueTabnr()
  if fugue_tab == -1
    call s:HideBrozOverlay()
    return
  endif
  if tabpagenr() == fugue_tab
    call s:ShowBrozOverlay()
  else
    call s:HideBrozOverlay()
  endif
endfunction

function! s:OnTabNew() abort
  call s:LogDebug('TabNew event')
  call s:HideBrozOverlay()
endfunction

function! s:OnTabClosed() abort
  if s:fugue_winid == -1
    return
  endif
  call s:LogDebug('TabClosed event')
  if win_id2win(s:fugue_winid) != 0
    return
  endif
  call s:HideBrozOverlay()
  let s:fugue_winid = -1
endfunction

function! s:GetFugueTabnr() abort
  if s:fugue_winid == -1
    return -1
  endif
  if exists('*win_id2tabwin')
    let tabinfo = win_id2tabwin(s:fugue_winid)
    if type(tabinfo) == v:t_list && len(tabinfo) >= 1 && tabinfo[0] > 0
      return tabinfo[0]
    endif
  endif
  for tabdata in gettabinfo()
    if has_key(tabdata, 'windows') && index(tabdata.windows, s:fugue_winid) >= 0
      return tabdata.tabnr
    endif
  endfor
  return -1
endfunction

function! s:OnVimResized() abort
  if !exists('*timer_start')
    call s:RefreshMacVimBounds()
    return
  endif
  if s:bounds_timer != -1
    call timer_stop(s:bounds_timer)
    let s:bounds_timer = -1
  endif
  let s:bounds_timer = timer_start(1000, {-> s:RefreshMacVimBounds()})
endfunction

function! s:RefreshMacVimBounds() abort
  let s:bounds_timer = -1
  let s:last_winpos = []
  call s:TriggerUpdate(0)
endfunction

function! FugueApi_FocusOverlayWindow(bufnr, args) abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  let @w=s:fugue_winid
  let @v=bufnr()
  "call win_execute(s:fugue_winid, 'call feedkeys("\<C-w>:", "ntx")')
endfunction

function! FugueApi_ReFocusMacVim(bufnr, args) abort
  call s:RefocusMacVim()
endfunction

function! s:StopBroz() abort
  call s:StopStateWatcher()
  if type(s:broz_job) == v:t_job
    try
      if job_status(s:broz_job) ==# 'run'
        call job_stop(s:broz_job, 'term')
      endif
    catch /^Vim\%((\a\+)\)\=:E\d\+/
      " Ignore invalid job handle when stopping
    endtry
  endif
  call s:ClearBrozState()
  if s:focus_timer != -1
    call timer_stop(s:focus_timer)
    let s:focus_timer = -1
  endif
  if s:bounds_timer != -1
    call timer_stop(s:bounds_timer)
    let s:bounds_timer = -1
  endif
endfunction

function! s:ClearBrozState() abort
  let s:broz_job = v:null
  let s:broz_bufnr = -1
  let s:fugue_winid = -1
  let s:last_payload = {}
  let s:last_window_metrics = {}
  let s:last_cell_pixels = []
  let s:broz_hidden = 0
  let s:last_winpos = []
  let s:vim_window_id = ''
  if s:initial_geometry_timer != -1
    call timer_stop(s:initial_geometry_timer)
  endif
  let s:initial_geometry_timer = -1
  if s:show_timer != -1
    call timer_stop(s:show_timer)
  endif
  let s:show_timer = -1
endfunction

function! s:EnsureVimWindowId() abort
  if empty(s:vim_window_id)
    call s:GetYabaiWindowId()
  endif
  return s:vim_window_id
endfunction

function! s:RefocusMacVim() abort
  if !has('mac') || !executable('yabai')
    return
  endif
  let winid = s:EnsureVimWindowId()
  if empty(winid)
    return
  endif
  call s:LogDebug('[fugue] refocus requesting yabai window ' . winid)
  let cmd = ['yabai', '-m', 'window', '--focus', winid]
  if exists('*job_start')
    try
      call job_start(cmd, {'detach': 1})
      return
    catch
    endtry
  endif
  call system(join(map(copy(cmd), 'shellescape(v:val)'), ' ') . ' >/dev/null 2>&1 &')
endfunction

function! s:GetYabaiWindowId() abort
  if !has('mac')
    call s:LogDebug('[fugue] yabai window id skipped: not macOS')
    return ''
  endif
  if !executable('yabai') || !executable('jq')
    call s:LogDebug('[fugue] yabai window id skipped: yabai/jq missing')
    return ''
  endif
  let id_cmd = 'yabai -m query --windows --space | jq -rc ''.[] | select(.app=="MacVim") | {id:.id,has_focus:.["has-focus"]}'''
  try
    let raw_entries = systemlist(id_cmd)
  catch
    call s:LogDebug('[fugue] yabai window id command threw exception')
    return ''
  endtry
  call s:LogDebug('[fugue] yabai id output=' . string(raw_entries) . ' exit=' . v:shell_error)
  if v:shell_error || empty(raw_entries)
    return ''
  endif
  let winid = ''
  let focus_state = ''
  for entry in raw_entries
    let trimmed = trim(entry)
    if empty(trimmed)
      continue
    endif
    try
      let parsed = json_decode(trimmed)
    catch
      continue
    endtry
    if type(parsed) != v:t_dict || !has_key(parsed, 'id')
      continue
    endif
    let current_id = string(parsed.id)
    let current_focus = get(parsed, 'has_focus', 0) ? 'true' : 'false'
    if current_focus ==# 'true'
      let winid = current_id
      let focus_state = current_focus
      break
    endif
    if empty(winid)
      let winid = current_id
      let focus_state = current_focus
    endif
  endfor
  if empty(winid)
    return ''
  endif
  call s:LogDebug('[fugue] yabai focus=' . focus_state . ' window_id=' . winid)
  let s:vim_window_id = winid
  return winid
endfunction

function! s:TriggerUpdate(timer) abort
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    return
  endif
  try
    if job_status(s:broz_job) !=# 'run'
      return
    endif
  catch /^Vim\%((\a\+)\)\=:E\d\+/
    let s:broz_job = v:null
    return
  endtry
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  let payload = s:GatherGeometry()
  if empty(payload)
    call s:LogDebug('[fugue] payload empty, skip update')
    return
  endif
  if s:broz_hidden
    let s:last_payload = copy(payload)
    return
  endif
  if !empty(s:last_payload) && s:PayloadEquals(s:last_payload, payload)
    return
  endif
  let s:last_payload = copy(payload)
  call s:LogDebug('[fugue] updating broz with ' . json_encode(payload))
  call s:SafeResizeBroz(payload)
endfunction

function! s:OnBrozExit(job, status) abort
  call s:LogDebug('[fugue] broz job exited status=' . a:status)
  call s:ClearBrozState()
endfunction


function! s:LogDebug(msg) abort
  if empty(s:log_path)
    return
  endif
  let entry = printf('%s %s', strftime('%Y-%m-%d %H:%M:%S'), a:msg)
  call writefile([entry], s:log_path, 'a')
endfunction

function! s:ToInt(value) abort
  if type(a:value) == type(0.0)
    return float2nr(a:value)
  endif
  return a:value
endfunction

function! s:StartStateWatcher() abort
  if !exists('*timer_start')
    return
  endif
  if s:state_timer != -1
    call timer_stop(s:state_timer)
  endif
  let s:last_window_metrics = {}
  let s:last_cell_pixels = getcellpixels()
  let s:last_winpos = []
  let s:state_timer = timer_start(200, function('s:PollWindowState'), {'repeat': -1})
endfunction

function! s:StopStateWatcher() abort
  if s:state_timer != -1
    call timer_stop(s:state_timer)
    let s:state_timer = -1
  endif
endfunction

function! s:PollWindowState(timer) abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  if s:broz_job is v:null || type(s:broz_job) != v:t_job
    return
  endif
  let info = getwininfo(s:fugue_winid)
  if empty(info)
    return
  endif
  let w = info[0]
  let current_metrics = {
        \ 'row': w.winrow,
        \ 'col': w.wincol,
        \ 'width': w.width,
        \ 'height': w.height,
        \ }
  let needs_update = 0
  if empty(s:last_window_metrics) || s:last_window_metrics !=# current_metrics
    let s:last_window_metrics = current_metrics
    let needs_update = 1
  endif
  let pixels = getcellpixels()
  if type(pixels) == v:t_list
    if empty(s:last_cell_pixels) || s:last_cell_pixels !=# pixels
      let s:last_cell_pixels = pixels
      let needs_update = 1
    endif
  endif
  if exists('*getwinpos')
    let pos = getwinpos()
    if type(pos) == v:t_list && len(pos) == 2
      if empty(s:last_winpos) || s:last_winpos[0] !=# pos[0] || s:last_winpos[1] !=# pos[1]
        let s:last_winpos = pos
        call s:ScheduleBoundsRefresh()
      endif
    endif
  endif
  if needs_update
    call s:TriggerUpdate(0)
  endif
endfunction

function! s:ScheduleBoundsRefresh() abort
  if !exists('*timer_start')
    call s:RefreshMacVimBounds()
    return
  endif
  if s:bounds_timer != -1
    call timer_stop(s:bounds_timer)
  endif
  let s:bounds_timer = timer_start(1000, {-> s:RefreshMacVimBounds()})
endfunction

function! s:PayloadEquals(left, right) abort
  let keys = ['widthPx', 'heightPx', 'topPxWin', 'leftPxWin']
  for key in keys
    if get(a:left, key, v:null) !=# get(a:right, key, v:null)
      return 0
    endif
  endfor
  return 1
endfunction

function! FugueApi_SendKeys(bufnr, args) abort
  if s:fugue_winid == -1 || !win_id2win(s:fugue_winid)
    return
  endif
  if type(a:args) != v:t_list || empty(a:args)
    return
  endif
  call win_gotoid(s:fugue_winid)
  for key in a:args
    if type(key) != v:t_string || empty(key)
      continue
    endif
    call feedkeys(key, 'n')
  endfor
endfunction
function! s:DebugFugueCommand() abort
  if !has('terminal') || !exists('*term_start')
    echoerr '[fugue] :terminal not supported'
    return
  endif
  let cmd = ['broz.js', '--top']
  call s:GetYabaiWindowId()
  let target_url = s:broz_url
  call add(cmd, target_url)
  let opts = {
        \ 'curwin': 1,
        \ 'term_kill': 'term',
        \ 'term_name': 'Fugue Debug Broz',
        \ }
  call term_start(cmd, opts)
endfunction
