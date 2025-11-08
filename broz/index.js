// @ts-check
const process = require('node:process')
const { cac } = require('cac')
const { app, BrowserWindow, Menu } = require('electron')
const createState = require('electron-window-state')
const readline = require('node:readline')
const { execFile } = require('node:child_process')

function callVimApi(functionName, args = []) {
  try {
    if (!process.stdout || process.stdout.destroyed)
      return
    const payload = JSON.stringify(['call', functionName, args])
    process.stdout.write(`\u001b]51;${payload}\u0007`)
  }
  catch (error) {
    console.error('runtime window control error: failed to notify vim api:', error)
  }
}

function parseOptionalNumber(value) {
  if (value === undefined)
    return undefined
  const number = Number(value)
  return Number.isFinite(number) ? number : undefined
}

let main = null

const cli = cac('broz')

cli
  .command('[url]', 'launch broz')
  .option('top', 'set window always on top')
  .option('height <height>', 'set initial window height')
  .option('width <width>', 'set initial window width')
  .option('x <x>', 'set initial window x position')
  .option('y <y>', 'set initial window y position')
  .option('frame', 'set window has a frame')
  .action(async (url, options) => {
    const args = {
      url: url || 'https://github.com/antfu/broz#readme',
      top: options.top || false,
      height: parseOptionalNumber(options.height),
      width: parseOptionalNumber(options.width),
      x: parseOptionalNumber(options.x),
      y: parseOptionalNumber(options.y),
      frame: options.frame || false,
    }

    app.setName('Broz')
    app.on('window-all-closed', () => app.quit())

    try {
      await app.whenReady()

      if (process.platform === 'darwin' && app.dock?.hide)
        app.dock.hide()

      Menu.setApplicationMenu(null)
      main = createMainWindow(args)
      setupRuntimeControls(main)

      await main.loadURL(
        args.url.includes('://')
          ? args.url
          : `http://${args.url}`,
      )
    }
    catch (e) {
      console.error(e)
      process.exit(1)
    }
  })

cli.help()
cli.parse()

function createMainWindow(args) {
  const state = createState({
    defaultWidth: 960,
    defaultHeight: 540,
  })

  const initialX = Number.isFinite(args.x) ? Math.round(args.x) : state.x
  const initialY = Number.isFinite(args.y) ? Math.round(args.y) : state.y
  const initialWidth = Number.isFinite(args.width) ? Math.round(args.width) : state.width
  const initialHeight = Number.isFinite(args.height) ? Math.round(args.height) : state.height

  const main = new BrowserWindow({
    x: initialX,
    y: initialY,
    width: initialWidth,
    height: initialHeight,
    show: false,
    frame: args.frame,
    titleBarStyle: 'hidden',
    trafficLightPosition: { x: -100, y: -100 },
    hasShadow: false,
    roundedCorners: false,
    fullscreenable: false,
    alwaysOnTop: args.top,
    backgroundColor: '#00000000',
    transparent: true,
    resizable: false,
  })

  main.setHasShadow(false)
  if (process.platform === 'darwin' && main.setRoundedCorners)
    main.setRoundedCorners(false)
  if (main.setResizable)
    main.setResizable(false)
  if (args.top)
    main.setAlwaysOnTop(true, 'screen-saver')
  if (main.setWindowButtonVisibility)
    main.setWindowButtonVisibility(false)

  main.on('resize', () => {
    const [width, height] = main.getSize()
    const [x, y] = main.getPosition()
    console.log(`size=${width}x${height} pos=${x},${y}`)
  })

  state.manage(main)
  const debouncedSaveWindowState = debounce(
    event => state.saveState(event.sender),
    500,
  )

  main.on('resize', debouncedSaveWindowState)
  main.on('move', debouncedSaveWindowState)

  configureWindow(main, args)
  if (typeof main.showInactive === 'function') {
    main.once('ready-to-show', () => {
      main.showInactive()
    })
  }
  else {
    main.once('ready-to-show', () => {
      main.show()
    })
  }

  return main
}

/**
 * @param {BrowserWindow} win
 */
function configureWindow(win, args) {
  // injecting a dragable area
  win.webContents.on('dom-ready', () => {
    win.webContents.executeJavaScript(`;(() => {
const el = document.createElement('div')
el.id = 'injected-broz-drag'
const style = document.createElement('style')
style.innerHTML="#injected-broz-drag{position:fixed;left:10px;top:10px;width:40px;height:40px;border-radius:50%;cursor:grab;-webkit-app-region:drag;z-index:2147483647;}#injected-broz-drag:hover{background:#8885;}"
document.body.appendChild(el)
document.body.appendChild(style)

const rootStyle = document.createElement('style')
rootStyle.innerHTML="::-webkit-scrollbar {display: none;}"
document.head.appendChild(rootStyle)

})()`)
  })

  win.webContents.setWindowOpenHandler(() => {
    const [x, y] = win.getPosition()
    const [width, height] = win.getSize()
    return {
      action: 'allow',
      overrideBrowserWindowOptions: {
        x: x + 50,
        y: y + 50,
        width,
        height,
      },
    }
  })

  win.webContents.on('before-input-event', (event, input) => {
    if (input.control || input.meta) {
      if (input.key === ']') {
        win.webContents.goForward()
        event.preventDefault()
      }
      else if (input.key === '[') {
        win.webContents.goBack()
        event.preventDefault()
      }
      else if (input.key.toLowerCase() === 'w') {
        callVimApi('FugueApi_FocusOverlayWindow', [])
        if (process.platform === 'darwin') {
          execFile('osascript', ['-e', `tell application "System Events" to tell application "MacVim" to activate`]).on('error', (error) => {
            console.error('runtime window control error: failed to activate macvim:', error)
          })
        }
        event.preventDefault()
      }
      else if (input.key === '-') {
        win.webContents.emit('zoom-changed', event, 'out')
        event.preventDefault()
      }
      else if (input.key === '=') {
        win.webContents.emit('zoom-changed', event, 'in')
        event.preventDefault()
      }
    }
  })

  win.webContents.on('did-create-window', (win) => {
    configureWindow(win, args)
  })

  win.webContents.on('zoom-changed', (event, zoomDirection) => {
    const currentZoom = win.webContents.getZoomFactor()
    if (zoomDirection === 'in')
      win.webContents.zoomFactor = currentZoom + 0.15

    if (zoomDirection === 'out')
      win.webContents.zoomFactor = currentZoom - 0.15
  })

  if (args.top)
    win.setAlwaysOnTop(true, 'floating')

  return win
}

function setupRuntimeControls(win) {
  if (!process.stdin || process.stdin.destroyed)
    return

  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  })

  rl.on('line', (line) => {
    const trimmed = line.trim()
    if (!trimmed)
      return
    if (!(trimmed.startsWith('{') || trimmed.startsWith('[')))
      return
    try {
      const payload = JSON.parse(trimmed)
      const action = typeof payload?.action === 'string' ? payload.action.toLowerCase() : null
      if (action === 'hide') {
        if (!win.isDestroyed() && win.isVisible() && !win.isFocused())
          win.hide()
        return
      }
      if (action === 'show') {
        if (win.isDestroyed())
          return
        if (win.isMinimized())
          win.restore()
        if (!win.isVisible()) {
          if (typeof win.showInactive === 'function')
            win.showInactive()
          else
            win.show()
        }
        else if (typeof win.showInactive === 'function') {
          win.showInactive()
        }
      }
      if (typeof payload.url === 'string' && payload.url.trim().length) {
        const rawUrl = payload.url.trim()
        const hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(rawUrl)
        const finalUrl = hasScheme ? rawUrl : `http://${rawUrl}`
        win.loadURL(finalUrl).catch((error) => {
          console.error('runtime window control error: failed to load url:', error)
        })
      }
      let positionChanged = false
      let sizeChanged = false

      let x = null
      let y = null
      if (Number.isFinite(payload.x) || Number.isFinite(payload.y)) {
        const [currentX, currentY] = win.getPosition()
        x = Number.isFinite(payload.x) ? Math.round(payload.x) : currentX
        y = Number.isFinite(payload.y) ? Math.round(payload.y) : currentY
        positionChanged = true
      }

      let width = null
      let height = null
      if (Number.isFinite(payload.width) || Number.isFinite(payload.height)) {
        const [currentWidth, currentHeight] = win.getSize()
        width = Number.isFinite(payload.width) ? Math.round(payload.width) : currentWidth
        height = Number.isFinite(payload.height) ? Math.round(payload.height) : currentHeight
        sizeChanged = true
      }

      if (positionChanged)
        win.setPosition(x, y)
      if (sizeChanged)
        win.setSize(width, height)
    }
    catch (error) {
      console.error('runtime window control error:', error)
    }
  })
}

function debounce(fn, delay) {
  let timeoutID = null
  return function (...args) {
    clearTimeout(timeoutID)
    timeoutID = setTimeout(() => {
      fn(...args)
    }, delay)
  }
}
