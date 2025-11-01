// @ts-check
const process = require('node:process')
const { cac } = require('cac')
const { app, BrowserWindow, Menu } = require('electron')
const createState = require('electron-window-state')

let main = null

const cli = cac('broz')

cli
  .command('[url]', 'launch broz')
  .option('top', 'set window always on top')
  .option('height <height>', 'set initial window height')
  .option('width <width>', 'set initial window width')
  .option('frame', 'set window has a frame')
  .action(async (url, options) => {
    const args = {
      url: url || 'https://github.com/antfu/broz#readme',
      top: options.top || false,
      height: options.height ? Number(options.height) : undefined,
      width: options.width ? Number(options.width) : undefined,
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

  const main = new BrowserWindow({
    x: state.x,
    y: state.y,
    width: args.width ?? state.width,
    height: args.height ?? state.height,
    show: true,
    frame: args.frame,
    titleBarStyle: 'hidden',
    trafficLightPosition: { x: -100, y: -100 },
    hasShadow: false,
    roundedCorners: false,
    fullscreenable: false,
    alwaysOnTop: args.top,
    backgroundColor: '#00000000',
    transparent: true,
  })

  main.setHasShadow(false)
  if (process.platform === 'darwin' && main.setRoundedCorners)
    main.setRoundedCorners(false)
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

function debounce(fn, delay) {
  let timeoutID = null
  return function (...args) {
    clearTimeout(timeoutID)
    timeoutID = setTimeout(() => {
      fn(...args)
    }, delay)
  }
}
