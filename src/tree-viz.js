Parser = require('tree-sitter')

let view = null, tree = null, doc = null
process.nextTick(init)

function destroy() {
  view && view.parentNode && view.parentNode.removeChild(view)
  view = null
}

function init() {
  atom.workspace.onDidChangeActiveTextEditor(setEditor)
  setEditor(atom.workspace.getActiveTextEditor())
  requestAnimationFrame(frame)
}

class YoloQueue {
  constructor(buffer) {
    this.nextIndex = 1
    this.array = new Uint32Array(buffer)
  }

  dequeue() {
    const {array, nextIndex: i} = this
    if (i === array[0]) return
    const a = array[i * 2], b = array[i * 2 + 1]
    if (++this.nextIndex * 2 > array.length)
      this.nextIndex = 1
    return [a, b]
  }
}

const trashQueue = new YoloQueue(Parser.trash)
const editQueue = new YoloQueue(Parser.edits)

let lastTrashIndex = 1
function frame() {
  requestAnimationFrame(frame)
  const dead = trashQueue.dequeue()
  if (dead) nodeWasDestroyed(keyForNode(dead))
  const edited = editQueue.dequeue()
  const node = edited && tree._getCachedNode(...edited)
  if (node) updateNode(node)
  // if (edited && !node) {
  //   console.log('zombie key?', edited)
  // }
}

function setupView(editor) {
  if (editor.treeVizElement) return editor.treeVizElement
  doc = editor.editorElement.ownerDocument
  const page = editor.editorElement
    .getElementsByClassName('scroll-view')[0]
    .firstElementChild
  const view = doc.createElement('div')
  Object.assign(view.style, {
    background: 'fuchsia',
    position: 'absolute',
    bottom: 'auto',
    right: '16px',
    left: 'auto',
    top: 0,
    width: '256px',
    height: '100%',
    zIndex: 1000,
  })
  page.appendChild(view)
  editor.treeVizElement = view
  return view  
}

let treeSubscription = null
function setupLanguageMode(lm) {
  if (tree) tree.didCacheNode = null
  tree = lm.tree
  tree.didCacheNode = updateNode
  tree.rootNode.descendantsOfType()
  treeSubscription && treeSubscription.dispose()
  treeSubscription = lm.onDidChangeHighlighting(range => {
    tree.rootNode.descendantsOfType(null, range.start, range.end)
    tree._dumpCache()
  })
}

function createNodeView() {
  const nodeView = doc.createElement('div')
  nodeView.className = 'tree-viz-node'
  Object.assign(nodeView.style, {
    position: 'absolute',
    background: 'lightblue',
    opacity: 0.5,
    border: 'thin solid blue'
  })
  return nodeView
}

function nodeWasDestroyed(key) {
  const nodeView = nodes[key]
  if (!nodeView) return
  nodeView.parentNode.removeChild(nodeView)
  delete nodes[key]
}

const nodes = {}

const keyForNode = node => `${node[0]}:${node[1]}`

/**
 * @param {Parser.SyntaxNode} node
 */
function updateNode(node) {
  const key = keyForNode(node)
  const nodeView = nodes[key] || (nodes[key] = createNodeView())
  const {startPosition, endPosition, type} = node
  const left = 18 * Math.min(startPosition.column, endPosition.column) + node.depth + 'px'
  if (startPosition.row === endPosition.row) {
    Object.assign(nodeView.style, {
      top: 18 * startPosition.row + 'px',
      left,
      bottom: endPosition.row * 18 + 'px',
      width: '18px',
      zIndex: 10 * node.depth,
    })
  } else {
    Object.assign(nodeView.style, {
      top: 18 * startPosition.row + 'px',
      left,
      height: (endPosition.row - startPosition.row + 1) * 18 + 'px',
      right: 18 * Math.max(startPosition.column, endPosition.column) + 'px',
      zIndex: 10 * node.depth,
    })
    nodeView.textContent = node.type
  }
  view.appendChild(nodeView)
}

function setEditor(editor) {
  global.ed = editor
  if (!editor) return destroy()
  if (!editor.languageMode.tree) return destroy() 

  view = setupView(editor)
  setupLanguageMode(editor.languageMode)
}

global.treeViz = {nodes}