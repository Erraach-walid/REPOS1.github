{CompositeDisposable, Emitter} = require 'event-kit'
{Point, Range} = require 'text-buffer'
_ = require 'underscore-plus'
Decoration = require './decoration'

module.exports =
class TextEditorPresenter
  toggleCursorBlinkHandle: null
  startBlinkingCursorsAfterDelay: null
  stoppedScrollingTimeoutId: null
  overlayDimensions: null
  minimumReflowInterval: 200

  constructor: (params) ->
    {@model, @lineTopIndex} = params
    @model.presenter = this
    {@cursorBlinkPeriod, @cursorBlinkResumeDelay, @stoppedScrollingDelay, @tileSize, @autoHeight} = params
    {@contentFrameWidth} = params
    {@displayLayer} = @model

    @gutterWidth = 0
    @tileSize ?= 6
    @realScrollTop = @scrollTop
    @realScrollLeft = @scrollLeft
    @disposables = new CompositeDisposable
    @emitter = new Emitter
    @linesByScreenRow = new Map
    @visibleHighlights = {}
    @characterWidthsByScope = {}
    @lineDecorationsByScreenRow = {}
    @lineNumberDecorationsByScreenRow = {}
    @customGutterDecorationsByGutterName = {}
    @overlayDimensions = {}
    @observedBlockDecorations = new Set()
    @invalidatedDimensionsByBlockDecoration = new Set()
    @invalidateAllBlockDecorationsDimensions = false
    @precedingBlockDecorationsByScreenRowAndId = {}
    @followingBlockDecorationsByScreenRowAndId = {}
    @screenRowsToMeasure = []
    @flashCountsByDecorationId = {}
    @transferMeasurementsToModel()
    @transferMeasurementsFromModel()
    @observeModel()
    @buildState()
    @invalidateState()
    @startBlinkingCursors() if @focused
    @startReflowing() if @continuousReflow
    @updating = false

  setLinesYardstick: (@linesYardstick) ->

  getLinesYardstick: -> @linesYardstick

  destroy: ->
    @disposables.dispose()
    clearTimeout(@stoppedScrollingTimeoutId) if @stoppedScrollingTimeoutId?
    clearInterval(@reflowingInterval) if @reflowingInterval?
    @stopBlinkingCursors()

  # Calls your `callback` when some changes in the model occurred and the current state has been updated.
  onDidUpdateState: (callback) ->
    @emitter.on 'did-update-state', callback

  emitDidUpdateState: ->
    @emitter.emit "did-update-state" if @isBatching()

  transferMeasurementsToModel: ->
    @model.setLineHeightInPixels(@lineHeight) if @lineHeight?
    @model.setDefaultCharWidth(@baseCharacterWidth) if @baseCharacterWidth?
    @model.setWidth(@contentFrameWidth) if @contentFrameWidth?

  transferMeasurementsFromModel: ->
    @editorWidthInChars = @model.getEditorWidthInChars()

  # Private: Determines whether {TextEditorPresenter} is currently batching changes.
  # Returns a {Boolean}, `true` if is collecting changes, `false` if is applying them.
  isBatching: ->
    @updating is false

  getPreMeasurementState: ->
    @updating = true

    @updateVerticalDimensions()

    @updateStartRow()
    @updateEndRow()
    @updateCommonGutterState()
    @updateReflowState()

    @updateLines()

    if @shouldUpdateDecorations
      @fetchDecorations()
      @updateLineDecorations()
      @updateBlockDecorations()

    @updateTilesState()

    @updating = false
    @state

  getPostMeasurementState: ->
    @updating = true

    @updateHorizontalDimensions()
    @updateRowsPerPage()

    @updateLines()

    @updateHiddenInputState()
    @updateContentState()
    @updateFocusedState()
    @updateHeightState()
    @updateWidthState()
    @updateHighlightDecorations() if @shouldUpdateDecorations
    @updateTilesState()
    @updateCursorsState()
    @updateOverlaysState()
    @updateLineNumberGutterState()
    @updateGutterOrderState()
    @updateCustomGutterDecorationState()
    @updating = false

    @resetTrackedUpdates()
    @state

  resetTrackedUpdates: ->
    @shouldUpdateDecorations = false

  invalidateState: ->
    @shouldUpdateDecorations = true

  observeModel: ->
    @disposables.add @model.displayLayer.onDidReset =>
      @spliceBlockDecorationsInRange(0, Infinity, Infinity)
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

    @disposables.add @model.displayLayer.onDidChangeSync (changes) =>
      for change in changes
        startRow = change.start.row
        endRow = startRow + change.oldExtent.row
        @spliceBlockDecorationsInRange(startRow, endRow, change.newExtent.row - change.oldExtent.row)
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

    @disposables.add @model.onDidUpdateDecorations =>
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

    @disposables.add @model.onDidAddDecoration(@didAddBlockDecoration.bind(this))

    for decoration in @model.getDecorations({type: 'block'})
      this.didAddBlockDecoration(decoration)

    @disposables.add @model.onDidChangeGrammar(@didChangeGrammar.bind(this))
    @disposables.add @model.onDidChangePlaceholderText(@emitDidUpdateState.bind(this))
    @disposables.add @model.onDidChangeMini =>
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

    @disposables.add @model.onDidChangeLineNumberGutterVisible(@emitDidUpdateState.bind(this))

    @disposables.add @model.onDidAddCursor(@didAddCursor.bind(this))
    @disposables.add @model.onDidRequestAutoscroll(@requestAutoscroll.bind(this))
    @disposables.add @model.onDidChangeFirstVisibleScreenRow(@didChangeFirstVisibleScreenRow.bind(this))
    @observeCursor(cursor) for cursor in @model.getCursors()
    @disposables.add @model.onDidAddGutter(@didAddGutter.bind(this))
    return

  didChangeScrollPastEnd: ->
    @emitDidUpdateState()

  didChangeShowLineNumbers: ->
    @emitDidUpdateState()

  didChangeGrammar: ->
    @emitDidUpdateState()

  buildState: ->
    @state =
      hiddenInput: {}
      content:
        scrollingVertically: false
        cursorsVisible: false
        tiles: {}
        highlights: {}
        overlays: {}
        cursors: {}
        offScreenBlockDecorations: {}
      gutters: []
    # Shared state that is copied into ``@state.gutters`.
    @sharedGutterStyles = {}
    @customGutterDecorations = {}
    @lineNumberGutter =
      tiles: {}

  setContinuousReflow: (@continuousReflow) ->
    if @continuousReflow
      @startReflowing()
    else
      @stopReflowing()

  updateReflowState: ->
    @state.content.continuousReflow = @continuousReflow
    @lineNumberGutter.continuousReflow = @continuousReflow

  startReflowing: ->
    @reflowingInterval = setInterval(@emitDidUpdateState.bind(this), @minimumReflowInterval)

  stopReflowing: ->
    clearInterval(@reflowingInterval)
    @reflowingInterval = null

  updateFocusedState: ->
    @state.focused = @focused

  updateHeightState: ->
    if @autoHeight
      @state.height = @contentHeight
    else
      @state.height = null

  updateWidthState: ->
    if @model.getAutoWidth()
      @state.width = @state.content.width + @gutterWidth
    else
      @state.width = null

  updateHiddenInputState: ->
    return unless lastCursor = @model.getLastCursor()

    {top, left, height, width} = @pixelRectForScreenRange(lastCursor.getScreenRange())

    # The hidden input will cause the scroll view to scroll to the left when focused
    # if it is placed exactly at the scroll view's scrollLeft position. So we place
    # it one pixel further to the right.
    if @focused
      @state.hiddenInput.top = Math.max(Math.min(top, @realScrollTop + @height - height), @realScrollTop)
      @state.hiddenInput.left = Math.max(Math.min(left, @realScrollLeft + @contentFrameWidth - width), @scrollLeft + 1)
    else
      @state.hiddenInput.top = @realScrollTop
      @state.hiddenInput.left = @scrollLeft + 1

    @state.hiddenInput.height = height
    @state.hiddenInput.width = Math.max(width, 2)

  updateContentState: ->
    if @boundingClientRect?
      @sharedGutterStyles.maxHeight = @boundingClientRect.height
      @sharedGutterStyles.height = @contentHeight
      @state.content.maxHeight = @boundingClientRect.height
      @state.content.height = @contentHeight

    contentFrameWidth = @contentFrameWidth ? 0
    contentWidth = @contentWidth ? 0
    if @model.getAutoWidth()
      @state.content.width = contentWidth
    else
      @state.content.width = Math.max(contentWidth, contentFrameWidth)
    @state.content.backgroundColor = if @model.isMini() then null else @backgroundColor
    @state.content.placeholderText = if @model.isEmpty() then @model.getPlaceholderText() else null

  tileForRow: (row) ->
    row - (row % @tileSize)

  getStartTileRow: ->
    @tileForRow(@startRow ? 0)

  getEndTileRow: ->
    @tileForRow(@endRow ? 0)

  getScreenRowsToRender: ->
    startRow = @getStartTileRow()
    endRow = @getEndTileRow() + @tileSize

    screenRows = [startRow...endRow]
    longestScreenRow = @model.getApproximateLongestScreenRow()
    if longestScreenRow?
      screenRows.push(longestScreenRow)
    if @screenRowsToMeasure?
      screenRows.push(@screenRowsToMeasure...)

    screenRows = screenRows.filter (row) -> row >= 0
    screenRows.sort (a, b) -> a - b
    _.uniq(screenRows, true)

  getScreenRangesToRender: ->
    screenRows = @getScreenRowsToRender()
    screenRows.push(Infinity) # makes the loop below inclusive

    startRow = screenRows[0]
    endRow = startRow - 1
    screenRanges = []
    for row in screenRows
      if row is endRow + 1
        endRow++
      else
        screenRanges.push([startRow, endRow])
        startRow = endRow = row

    screenRanges

  setScreenRowsToMeasure: (screenRows) ->
    return if not screenRows? or screenRows.length is 0

    @screenRowsToMeasure = screenRows
    @shouldUpdateDecorations = true

  clearScreenRowsToMeasure: ->
    @screenRowsToMeasure = []

  updateTilesState: ->
    return unless @startRow? and @endRow? and @lineHeight?

    screenRows = @getScreenRowsToRender()
    visibleTiles = {}
    startRow = screenRows[0]
    endRow = screenRows[screenRows.length - 1]
    screenRowIndex = screenRows.length - 1
    zIndex = 0

    for tileStartRow in [@tileForRow(endRow)..@tileForRow(startRow)] by -@tileSize
      tileEndRow = tileStartRow + @tileSize
      rowsWithinTile = []

      while screenRowIndex >= 0
        currentScreenRow = screenRows[screenRowIndex]
        break if currentScreenRow < tileStartRow
        rowsWithinTile.push(currentScreenRow)
        screenRowIndex--

      continue if rowsWithinTile.length is 0

      top = Math.round(@lineTopIndex.pixelPositionBeforeBlocksForRow(tileStartRow))
      bottom = Math.round(@lineTopIndex.pixelPositionBeforeBlocksForRow(tileEndRow))
      height = bottom - top

      tile = @state.content.tiles[tileStartRow] ?= {}
      tile.top = top
      tile.left = 0
      tile.height = height
      tile.display = "block"
      tile.zIndex = zIndex
      tile.highlights ?= {}

      gutterTile = @lineNumberGutter.tiles[tileStartRow] ?= {}
      gutterTile.top = top - @scrollTop
      gutterTile.height = height
      gutterTile.display = "block"
      gutterTile.zIndex = zIndex

      @updateLinesState(tile, rowsWithinTile)
      @updateLineNumbersState(gutterTile, rowsWithinTile)

      visibleTiles[tileStartRow] = true
      zIndex++

    for id, tile of @state.content.tiles
      continue if visibleTiles.hasOwnProperty(id)

      delete @state.content.tiles[id]
      delete @lineNumberGutter.tiles[id]

  updateLinesState: (tileState, screenRows) ->
    tileState.lines ?= {}
    visibleLineIds = {}
    for screenRow in screenRows
      line = @linesByScreenRow.get(screenRow)
      continue unless line?

      visibleLineIds[line.id] = true
      precedingBlockDecorations = @precedingBlockDecorationsByScreenRowAndId[screenRow] ? {}
      followingBlockDecorations = @followingBlockDecorationsByScreenRowAndId[screenRow] ? {}
      if tileState.lines.hasOwnProperty(line.id)
        lineState = tileState.lines[line.id]
        lineState.screenRow = screenRow
        lineState.decorationClasses = @lineDecorationClassesForRow(screenRow)
        lineState.precedingBlockDecorations = precedingBlockDecorations
        lineState.followingBlockDecorations = followingBlockDecorations
      else
        tileState.lines[line.id] =
          screenRow: screenRow
          lineText: line.lineText
          tagCodes: line.tagCodes
          decorationClasses: @lineDecorationClassesForRow(screenRow)
          precedingBlockDecorations: precedingBlockDecorations
          followingBlockDecorations: followingBlockDecorations

    for id, line of tileState.lines
      delete tileState.lines[id] unless visibleLineIds.hasOwnProperty(id)
    return

  updateCursorsState: ->
    return unless @startRow? and @endRow? and @hasPixelRectRequirements() and @baseCharacterWidth?

    @state.content.cursors = {}
    for cursor in @model.cursorsForScreenRowRange(@startRow, @endRow - 1) when cursor.isVisible()
      pixelRect = @pixelRectForScreenRange(cursor.getScreenRange())
      pixelRect.width = Math.round(@baseCharacterWidth) if pixelRect.width is 0
      @state.content.cursors[cursor.id] = pixelRect
    return

  updateOverlaysState: ->
    return unless @hasOverlayPositionRequirements()

    visibleDecorationIds = {}

    for decoration in @model.getOverlayDecorations()
      continue unless decoration.getMarker().isValid()

      {item, position, class: klass, avoidOverflow} = decoration.getProperties()
      if position is 'tail'
        screenPosition = decoration.getMarker().getTailScreenPosition()
      else
        screenPosition = decoration.getMarker().getHeadScreenPosition()

      pixelPosition = @pixelPositionForScreenPosition(screenPosition)

      # Fixed positioning.
      top = @boundingClientRect.top + pixelPosition.top + @lineHeight - @scrollTop
      left = @boundingClientRect.left + pixelPosition.left + @gutterWidth - @scrollLeft

      if overlayDimensions = @overlayDimensions[decoration.id]
        {itemWidth, itemHeight, contentMargin} = overlayDimensions

        if avoidOverflow isnt false
          rightDiff = left + itemWidth + contentMargin - @windowWidth
          left -= rightDiff if rightDiff > 0

          leftDiff = left + contentMargin
          left -= leftDiff if leftDiff < 0

          if top + itemHeight > @windowHeight and
             top - (itemHeight + @lineHeight) >= 0
            top -= itemHeight + @lineHeight

      pixelPosition.top = top
      pixelPosition.left = left

      overlayState = @state.content.overlays[decoration.id] ?= {item}
      overlayState.pixelPosition = pixelPosition
      overlayState.class = klass if klass?
      visibleDecorationIds[decoration.id] = true

    for id of @state.content.overlays
      delete @state.content.overlays[id] unless visibleDecorationIds[id]

    for id of @overlayDimensions
      delete @overlayDimensions[id] unless visibleDecorationIds[id]

    return

  updateLineNumberGutterState: ->
    @lineNumberGutter.maxLineNumberDigits = Math.max(
      2,
      @model.getLineCount().toString().length
    )

  updateCommonGutterState: ->
    @sharedGutterStyles.backgroundColor = if @gutterBackgroundColor isnt "rgba(0, 0, 0, 0)"
      @gutterBackgroundColor
    else
      @backgroundColor

  didAddGutter: (gutter) ->
    gutterDisposables = new CompositeDisposable
    gutterDisposables.add gutter.onDidChangeVisible => @emitDidUpdateState()
    gutterDisposables.add gutter.onDidDestroy =>
      @disposables.remove(gutterDisposables)
      gutterDisposables.dispose()
      @emitDidUpdateState()
      # It is not necessary to @updateCustomGutterDecorationState here.
      # The destroyed gutter will be removed from the list of gutters in @state,
      # and thus will be removed from the DOM.
    @disposables.add(gutterDisposables)
    @emitDidUpdateState()

  updateGutterOrderState: ->
    @state.gutters = []
    if @model.isMini()
      return
    for gutter in @model.getGutters()
      isVisible = @gutterIsVisible(gutter)
      if gutter.name is 'line-number'
        content = @lineNumberGutter
      else
        @customGutterDecorations[gutter.name] ?= {}
        content = @customGutterDecorations[gutter.name]
      @state.gutters.push({
        gutter,
        visible: isVisible,
        styles: @sharedGutterStyles,
        content,
      })

  # Updates the decoration state for the gutter with the given gutterName.
  # @customGutterDecorations is an {Object}, with the form:
  #   * gutterName : {
  #     decoration.id : {
  #       top: # of pixels from top
  #       height: # of pixels height of this decoration
  #       item (optional): HTMLElement
  #       class (optional): {String} class
  #     }
  #   }
  updateCustomGutterDecorationState: ->
    return unless @startRow? and @endRow? and @lineHeight?

    if @model.isMini()
      # Mini editors have no gutter decorations.
      # We clear instead of reassigning to preserve the reference.
      @clearAllCustomGutterDecorations()

    for gutter in @model.getGutters()
      gutterName = gutter.name
      gutterDecorations = @customGutterDecorations[gutterName]
      if gutterDecorations
        # Clear the gutter decorations; they are rebuilt.
        # We clear instead of reassigning to preserve the reference.
        @clearDecorationsForCustomGutterName(gutterName)
      else
        @customGutterDecorations[gutterName] = {}

      continue unless @gutterIsVisible(gutter)
      for decorationId, {properties, screenRange} of @customGutterDecorationsByGutterName[gutterName]
        top = @lineTopIndex.pixelPositionAfterBlocksForRow(screenRange.start.row)
        bottom = @lineTopIndex.pixelPositionBeforeBlocksForRow(screenRange.end.row + 1)
        @customGutterDecorations[gutterName][decorationId] =
          top: top
          height: bottom - top
          item: properties.item
          class: properties.class

  clearAllCustomGutterDecorations: ->
    allGutterNames = Object.keys(@customGutterDecorations)
    for gutterName in allGutterNames
      @clearDecorationsForCustomGutterName(gutterName)

  clearDecorationsForCustomGutterName: (gutterName) ->
    gutterDecorations = @customGutterDecorations[gutterName]
    if gutterDecorations
      allDecorationIds = Object.keys(gutterDecorations)
      for decorationId in allDecorationIds
        delete gutterDecorations[decorationId]

  gutterIsVisible: (gutterModel) ->
    isVisible = gutterModel.isVisible()
    if gutterModel.name is 'line-number'
      isVisible = isVisible and @model.doesShowLineNumbers()
    isVisible

  updateLineNumbersState: (tileState, screenRows) ->
    tileState.lineNumbers ?= {}
    visibleLineNumberIds = {}

    for screenRow in screenRows when @isRowRendered(screenRow)
      line = @linesByScreenRow.get(screenRow)
      continue unless line?
      lineId = line.id
      {row: bufferRow, column: bufferColumn} = @displayLayer.translateScreenPosition(Point(screenRow, 0))
      softWrapped = bufferColumn isnt 0
      foldable = not softWrapped and @model.isFoldableAtBufferRow(bufferRow)
      decorationClasses = @lineNumberDecorationClassesForRow(screenRow)
      blockDecorationsBeforeCurrentScreenRowHeight = @lineTopIndex.pixelPositionAfterBlocksForRow(screenRow) - @lineTopIndex.pixelPositionBeforeBlocksForRow(screenRow)
      blockDecorationsHeight = blockDecorationsBeforeCurrentScreenRowHeight
      if screenRow % @tileSize isnt 0
        blockDecorationsAfterPreviousScreenRowHeight = @lineTopIndex.pixelPositionBeforeBlocksForRow(screenRow) - @lineHeight - @lineTopIndex.pixelPositionAfterBlocksForRow(screenRow - 1)
        blockDecorationsHeight += blockDecorationsAfterPreviousScreenRowHeight

      tileState.lineNumbers[lineId] = {screenRow, bufferRow, softWrapped, decorationClasses, foldable, blockDecorationsHeight}
      visibleLineNumberIds[lineId] = true

    for id of tileState.lineNumbers
      delete tileState.lineNumbers[id] unless visibleLineNumberIds[id]

    return

  updateStartRow: ->
    return unless @scrollTop? and @lineHeight?

    @startRow = Math.max(0, @lineTopIndex.rowForPixelPosition(@scrollTop))
    atom.assert(
      Number.isFinite(@startRow),
      'Invalid start row',
      (error) =>
        error.metadata = {
          startRow: @startRow?.toString(),
          scrollTop: @scrollTop?.toString(),
          scrollHeight: @scrollHeight?.toString(),
          clientHeight: @clientHeight?.toString(),
          lineHeight: @lineHeight?.toString()
        }
    )

  updateEndRow: ->
    return unless @scrollTop? and @lineHeight? and @height?

    @endRow = Math.min(
      @model.getApproximateScreenLineCount(),
      @lineTopIndex.rowForPixelPosition(@scrollTop + @height + @lineHeight - 1) + 1
    )

  updateRowsPerPage: ->
    rowsPerPage = Math.floor(@height / @lineHeight)
    if rowsPerPage isnt @rowsPerPage
      @rowsPerPage = rowsPerPage
      @model.setRowsPerPage(@rowsPerPage)

  updateVerticalDimensions: ->
    if @lineHeight?
      oldContentHeight = @contentHeight
      @contentHeight = Math.round(@lineTopIndex.pixelPositionAfterBlocksForRow(@model.getApproximateScreenLineCount()))

    if @contentHeight isnt oldContentHeight
      @updateHeight()

  updateHorizontalDimensions: ->
    if @baseCharacterWidth?
      oldContentWidth = @contentWidth
      rightmostPosition = @model.getApproximateRightmostScreenPosition()
      @contentWidth = @pixelPositionForScreenPosition(rightmostPosition).left
      @contentWidth += 1 unless @model.isSoftWrapped() # account for cursor width

  updateScrollTop: (scrollTop) ->
    if scrollTop isnt @realScrollTop and not Number.isNaN(scrollTop)
      @realScrollTop = scrollTop
      @scrollTop = Math.round(scrollTop)
      @shouldUpdateDecorations = true
      @model.setFirstVisibleScreenRow(Math.round(@scrollTop / @lineHeight), true)

      @updateStartRow()
      @updateEndRow()
      true
    else
      false

  updateScrollLeft: (scrollLeft) ->
    if scrollLeft isnt @realScrollLeft and not Number.isNaN(scrollLeft)
      @realScrollLeft = scrollLeft
      @scrollLeft = Math.round(scrollLeft)
      @model.setFirstVisibleScreenColumn(Math.round(@scrollLeft / @baseCharacterWidth))
      true
    else
      false

  lineDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for id, properties of @lineDecorationsByScreenRow[row]
      decorationClasses ?= []
      decorationClasses.push(properties.class)
    decorationClasses

  lineNumberDecorationClassesForRow: (row) ->
    return null if @model.isMini()

    decorationClasses = null
    for id, properties of @lineNumberDecorationsByScreenRow[row]
      decorationClasses ?= []
      decorationClasses.push(properties.class)
    decorationClasses

  getCursorBlinkPeriod: -> @cursorBlinkPeriod

  getCursorBlinkResumeDelay: -> @cursorBlinkResumeDelay

  setFocused: (focused) ->
    unless @focused is focused
      @focused = focused
      if @focused
        @startBlinkingCursors()
      else
        @stopBlinkingCursors(false)
      @emitDidUpdateState()

  setAutoHeight: (autoHeight) ->
    unless @autoHeight is autoHeight
      @autoHeight = autoHeight
      @emitDidUpdateState()

  setExplicitHeight: (explicitHeight) ->
    unless @explicitHeight is explicitHeight
      @explicitHeight = explicitHeight
      @updateHeight()
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

  updateHeight: ->
    height = @explicitHeight ? @contentHeight
    unless @height is height
      @height = height
      @model.setHeight(height, true)
      @updateEndRow()

  didChangeAutoWidth: ->
    @emitDidUpdateState()

  setContentFrameWidth: (contentFrameWidth) ->
    if @contentFrameWidth isnt contentFrameWidth or @editorWidthInChars?
      @contentFrameWidth = contentFrameWidth
      @model.setWidth(@contentFrameWidth, true)
      @editorWidthInChars = null
      @invalidateAllBlockDecorationsDimensions = true
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

  setBoundingClientRect: (boundingClientRect) ->
    unless @clientRectsEqual(@boundingClientRect, boundingClientRect)
      @boundingClientRect = boundingClientRect
      @invalidateAllBlockDecorationsDimensions = true
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

  clientRectsEqual: (clientRectA, clientRectB) ->
    clientRectA? and clientRectB? and
      clientRectA.top is clientRectB.top and
      clientRectA.left is clientRectB.left and
      clientRectA.width is clientRectB.width and
      clientRectA.height is clientRectB.height

  setWindowSize: (width, height) ->
    if @windowWidth isnt width or @windowHeight isnt height
      @windowWidth = width
      @windowHeight = height
      @invalidateAllBlockDecorationsDimensions = true
      @shouldUpdateDecorations = true

      @emitDidUpdateState()

  setBackgroundColor: (backgroundColor) ->
    unless @backgroundColor is backgroundColor
      @backgroundColor = backgroundColor
      @emitDidUpdateState()

  setGutterBackgroundColor: (gutterBackgroundColor) ->
    unless @gutterBackgroundColor is gutterBackgroundColor
      @gutterBackgroundColor = gutterBackgroundColor
      @emitDidUpdateState()

  setGutterWidth: (gutterWidth) ->
    if @gutterWidth isnt gutterWidth
      @gutterWidth = gutterWidth
      @updateOverlaysState()

  getGutterWidth: ->
    @gutterWidth

  setLineHeight: (lineHeight) ->
    unless @lineHeight is lineHeight
      @lineHeight = lineHeight
      @model.setLineHeightInPixels(@lineHeight)
      @lineTopIndex.setDefaultLineHeight(@lineHeight)
      @model.setLineHeightInPixels(lineHeight)
      @shouldUpdateDecorations = true
      @emitDidUpdateState()

  setBaseCharacterWidth: (baseCharacterWidth, doubleWidthCharWidth, halfWidthCharWidth, koreanCharWidth) ->
    unless @baseCharacterWidth is baseCharacterWidth and @doubleWidthCharWidth is doubleWidthCharWidth and @halfWidthCharWidth is halfWidthCharWidth and koreanCharWidth is @koreanCharWidth
      @baseCharacterWidth = baseCharacterWidth
      @doubleWidthCharWidth = doubleWidthCharWidth
      @halfWidthCharWidth = halfWidthCharWidth
      @koreanCharWidth = koreanCharWidth
      @model.setDefaultCharWidth(baseCharacterWidth, doubleWidthCharWidth, halfWidthCharWidth, koreanCharWidth)
      @measurementsChanged()

  measurementsChanged: ->
    @invalidateAllBlockDecorationsDimensions = true
    @shouldUpdateDecorations = true
    @emitDidUpdateState()

  hasPixelPositionRequirements: ->
    @lineHeight? and @baseCharacterWidth?

  pixelPositionAfterBlocksForRow: (row) ->
    @lineTopIndex.pixelPositionAfterBlocksForRow(row)

  pixelPositionForScreenPosition: (screenPosition) ->
    position = @linesYardstick.pixelPositionForScreenPosition(screenPosition)

    position.top = Math.round(position.top)
    position.left = Math.round(position.left)

    position

  hasPixelRectRequirements: ->
    @hasPixelPositionRequirements()

  hasOverlayPositionRequirements: ->
    @hasPixelRectRequirements() and @boundingClientRect? and @windowWidth and @windowHeight

  absolutePixelRectForScreenRange: (screenRange) ->
    lineHeight = @model.getLineHeightInPixels()

    if screenRange.end.row > screenRange.start.row
      top = @linesYardstick.pixelPositionForScreenPosition(screenRange.start).top
      left = 0
      height = (screenRange.end.row - screenRange.start.row + 1) * lineHeight
      width = Math.max(@contentWidth, @contentFrameWidth)
    else
      {top, left} = @linesYardstick.pixelPositionForScreenPosition(screenRange.start)
      height = lineHeight
      width = @linesYardstick.pixelPositionForScreenPosition(screenRange.end).left - left

    {top, left, width, height}

  pixelRectForScreenRange: (screenRange) ->
    rect = @absolutePixelRectForScreenRange(screenRange)
    rect.top = Math.round(rect.top)
    rect.left = Math.round(rect.left)
    rect.width = Math.round(rect.width)
    rect.height = Math.round(rect.height)
    rect

  updateLines: ->
    @linesByScreenRow.clear()

    for [startRow, endRow] in @getScreenRangesToRender()
      for line, index in @displayLayer.getScreenLines(startRow, endRow + 1)
        @linesByScreenRow.set(startRow + index, line)

  lineIdForScreenRow: (screenRow) ->
    @linesByScreenRow.get(screenRow)?.id

  fetchDecorations: ->
    return unless 0 <= @startRow <= @endRow <= Infinity
    @decorations = @model.decorationsStateForScreenRowRange(@startRow, @endRow - 1)

  updateBlockDecorations: ->
    if @invalidateAllBlockDecorationsDimensions
      for decoration in @model.getDecorations(type: 'block')
        @invalidatedDimensionsByBlockDecoration.add(decoration)
      @invalidateAllBlockDecorationsDimensions = false

    visibleDecorationsById = {}
    visibleDecorationsByScreenRowAndId = {}
    for markerId, decorations of @model.decorationsForScreenRowRange(@getStartTileRow(), @getEndTileRow() + @tileSize - 1)
      for decoration in decorations when decoration.isType('block')
        screenRow = decoration.getMarker().getHeadScreenPosition().row
        if decoration.getProperties().position is "after"
          @followingBlockDecorationsByScreenRowAndId[screenRow] ?= {}
          @followingBlockDecorationsByScreenRowAndId[screenRow][decoration.id] = {screenRow, decoration}
        else
          @precedingBlockDecorationsByScreenRowAndId[screenRow] ?= {}
          @precedingBlockDecorationsByScreenRowAndId[screenRow][decoration.id] = {screenRow, decoration}
        visibleDecorationsById[decoration.id] = true
        visibleDecorationsByScreenRowAndId[screenRow] ?= {}
        visibleDecorationsByScreenRowAndId[screenRow][decoration.id] = true

    for screenRow, blockDecorations of @precedingBlockDecorationsByScreenRowAndId
      for id, blockDecoration of blockDecorations
        unless visibleDecorationsByScreenRowAndId[screenRow]?[id]
          delete @precedingBlockDecorationsByScreenRowAndId[screenRow][id]

    for screenRow, blockDecorations of @followingBlockDecorationsByScreenRowAndId
      for id, blockDecoration of blockDecorations
        unless visibleDecorationsByScreenRowAndId[screenRow]?[id]
          delete @followingBlockDecorationsByScreenRowAndId[screenRow][id]

    @state.content.offScreenBlockDecorations = {}
    @invalidatedDimensionsByBlockDecoration.forEach (decoration) =>
      unless visibleDecorationsById[decoration.id]
        @state.content.offScreenBlockDecorations[decoration.id] = decoration

  updateLineDecorations: ->
    @lineDecorationsByScreenRow = {}
    @lineNumberDecorationsByScreenRow = {}
    @customGutterDecorationsByGutterName = {}

    for decorationId, decorationState of @decorations
      {properties, bufferRange, screenRange, rangeIsReversed} = decorationState
      if Decoration.isType(properties, 'line') or Decoration.isType(properties, 'line-number')
        @addToLineDecorationCaches(decorationId, properties, bufferRange, screenRange, rangeIsReversed)

      else if Decoration.isType(properties, 'gutter') and properties.gutterName?
        @customGutterDecorationsByGutterName[properties.gutterName] ?= {}
        @customGutterDecorationsByGutterName[properties.gutterName][decorationId] = decorationState

    return

  updateHighlightDecorations: ->
    @visibleHighlights = {}

    for decorationId, {properties, screenRange} of @decorations
      if Decoration.isType(properties, 'highlight')
        @updateHighlightState(decorationId, properties, screenRange)

    for tileId, tileState of @state.content.tiles
      for id of tileState.highlights
        delete tileState.highlights[id] unless @visibleHighlights[tileId]?[id]?

    return

  addToLineDecorationCaches: (decorationId, properties, bufferRange, screenRange, rangeIsReversed) ->
    if screenRange.isEmpty()
      return if properties.onlyNonEmpty
    else
      return if properties.onlyEmpty
      omitLastRow = screenRange.end.column is 0

    if rangeIsReversed
      headScreenPosition = screenRange.start
    else
      headScreenPosition = screenRange.end

    if properties.class is 'folded' and Decoration.isType(properties, 'line-number')
      screenRow = @model.screenRowForBufferRow(bufferRange.start.row)
      @lineNumberDecorationsByScreenRow[screenRow] ?= {}
      @lineNumberDecorationsByScreenRow[screenRow][decorationId] = properties
    else
      startRow = Math.max(screenRange.start.row, @getStartTileRow())
      endRow = Math.min(screenRange.end.row, @getEndTileRow() + @tileSize)
      for row in [startRow..endRow] by 1
        continue if properties.onlyHead and row isnt headScreenPosition.row
        continue if omitLastRow and row is screenRange.end.row

        if Decoration.isType(properties, 'line')
          @lineDecorationsByScreenRow[row] ?= {}
          @lineDecorationsByScreenRow[row][decorationId] = properties

        if Decoration.isType(properties, 'line-number')
          @lineNumberDecorationsByScreenRow[row] ?= {}
          @lineNumberDecorationsByScreenRow[row][decorationId] = properties

    return

  intersectRangeWithTile: (range, tileStartRow) ->
    intersectingStartRow = Math.max(tileStartRow, range.start.row)
    intersectingEndRow = Math.min(tileStartRow + @tileSize - 1, range.end.row)
    intersectingRange = new Range(
      new Point(intersectingStartRow, 0),
      new Point(intersectingEndRow, Infinity)
    )

    if intersectingStartRow is range.start.row
      intersectingRange.start.column = range.start.column

    if intersectingEndRow is range.end.row
      intersectingRange.end.column = range.end.column

    intersectingRange

  updateHighlightState: (decorationId, properties, screenRange) ->
    return unless @startRow? and @endRow? and @lineHeight? and @hasPixelPositionRequirements()

    @constrainRangeToVisibleRowRange(screenRange)

    return if screenRange.isEmpty()

    startTile = @tileForRow(screenRange.start.row)
    endTile = @tileForRow(screenRange.end.row)
    needsFlash = properties.flashCount? and @flashCountsByDecorationId[decorationId] isnt properties.flashCount
    if needsFlash
      @flashCountsByDecorationId[decorationId] = properties.flashCount

    for tileStartRow in [startTile..endTile] by @tileSize
      rangeWithinTile = @intersectRangeWithTile(screenRange, tileStartRow)

      continue if rangeWithinTile.isEmpty()

      tileState = @state.content.tiles[tileStartRow] ?= {highlights: {}}
      highlightState = tileState.highlights[decorationId] ?= {}

      highlightState.needsFlash = needsFlash
      highlightState.flashCount = properties.flashCount
      highlightState.flashClass = properties.flashClass
      highlightState.flashDuration = properties.flashDuration
      highlightState.class = properties.class
      highlightState.deprecatedRegionClass = properties.deprecatedRegionClass
      highlightState.regions = @buildHighlightRegions(rangeWithinTile)

      for region in highlightState.regions
        @repositionRegionWithinTile(region, tileStartRow)

      @visibleHighlights[tileStartRow] ?= {}
      @visibleHighlights[tileStartRow][decorationId] = true

    true

  constrainRangeToVisibleRowRange: (screenRange) ->
    if screenRange.start.row < @startRow
      screenRange.start.row = @startRow
      screenRange.start.column = 0

    if screenRange.end.row < @startRow
      screenRange.end.row = @startRow
      screenRange.end.column = 0

    if screenRange.start.row >= @endRow
      screenRange.start.row = @endRow
      screenRange.start.column = 0

    if screenRange.end.row >= @endRow
      screenRange.end.row = @endRow
      screenRange.end.column = 0

  repositionRegionWithinTile: (region, tileStartRow) ->
    region.top -= @lineTopIndex.pixelPositionBeforeBlocksForRow(tileStartRow)

  buildHighlightRegions: (screenRange) ->
    lineHeightInPixels = @lineHeight
    startPixelPosition = @pixelPositionForScreenPosition(screenRange.start)
    endPixelPosition = @pixelPositionForScreenPosition(screenRange.end)
    spannedRows = screenRange.end.row - screenRange.start.row + 1

    regions = []

    if spannedRows is 1
      region =
        top: startPixelPosition.top
        height: lineHeightInPixels
        left: startPixelPosition.left

      if screenRange.end.column is Infinity
        region.right = 0
      else
        region.width = endPixelPosition.left - startPixelPosition.left

      regions.push(region)
    else
      # First row, extending from selection start to the right side of screen
      regions.push(
        top: startPixelPosition.top
        left: startPixelPosition.left
        height: lineHeightInPixels
        right: 0
      )

      # Middle rows, extending from left side to right side of screen
      if spannedRows > 2
        regions.push(
          top: startPixelPosition.top + lineHeightInPixels
          height: endPixelPosition.top - startPixelPosition.top - lineHeightInPixels
          left: 0
          right: 0
        )

      # Last row, extending from left side of screen to selection end
      if screenRange.end.column > 0
        region =
          top: endPixelPosition.top
          height: lineHeightInPixels
          left: 0

        if screenRange.end.column is Infinity
          region.right = 0
        else
          region.width = endPixelPosition.left

        regions.push(region)

    regions

  setOverlayDimensions: (decorationId, itemWidth, itemHeight, contentMargin) ->
    @overlayDimensions[decorationId] ?= {}
    overlayState = @overlayDimensions[decorationId]
    dimensionsAreEqual = overlayState.itemWidth is itemWidth and
      overlayState.itemHeight is itemHeight and
      overlayState.contentMargin is contentMargin
    unless dimensionsAreEqual
      overlayState.itemWidth = itemWidth
      overlayState.itemHeight = itemHeight
      overlayState.contentMargin = contentMargin

      @emitDidUpdateState()

  setBlockDecorationDimensions: (decoration, width, height) ->
    return unless @observedBlockDecorations.has(decoration)

    @lineTopIndex.resizeBlock(decoration.id, height)

    @invalidatedDimensionsByBlockDecoration.delete(decoration)
    @shouldUpdateDecorations = true
    @emitDidUpdateState()

  invalidateBlockDecorationDimensions: (decoration) ->
    @invalidatedDimensionsByBlockDecoration.add(decoration)
    @shouldUpdateDecorations = true
    @emitDidUpdateState()

  spliceBlockDecorationsInRange: (start, end, screenDelta) ->
    return if screenDelta is 0

    oldExtent = end - start
    newExtent = end - start + screenDelta
    invalidatedBlockDecorationIds = @lineTopIndex.splice(start, oldExtent, newExtent)
    invalidatedBlockDecorationIds.forEach (id) =>
      decoration = @model.decorationForId(id)
      newScreenPosition = decoration.getMarker().getHeadScreenPosition()
      @lineTopIndex.moveBlock(id, newScreenPosition.row)
      @invalidatedDimensionsByBlockDecoration.add(decoration)

  didAddBlockDecoration: (decoration) ->
    return if not decoration.isType('block') or @observedBlockDecorations.has(decoration)

    didMoveDisposable = decoration.getMarker().bufferMarker.onDidChange (markerEvent) =>
      @didMoveBlockDecoration(decoration, markerEvent)

    didDestroyDisposable = decoration.onDidDestroy =>
      @disposables.remove(didMoveDisposable)
      @disposables.remove(didDestroyDisposable)
      didMoveDisposable.dispose()
      didDestroyDisposable.dispose()
      @didDestroyBlockDecoration(decoration)

    isAfter = decoration.getProperties().position is "after"
    @lineTopIndex.insertBlock(decoration.id, decoration.getMarker().getHeadScreenPosition().row, 0, isAfter)

    @observedBlockDecorations.add(decoration)
    @invalidateBlockDecorationDimensions(decoration)
    @disposables.add(didMoveDisposable)
    @disposables.add(didDestroyDisposable)
    @shouldUpdateDecorations = true
    @emitDidUpdateState()

  didMoveBlockDecoration: (decoration, markerEvent) ->
    # Don't move blocks after a text change, because we already splice on buffer
    # change.
    return if markerEvent.textChanged

    @lineTopIndex.moveBlock(decoration.id, decoration.getMarker().getHeadScreenPosition().row)
    @shouldUpdateDecorations = true
    @emitDidUpdateState()

  didDestroyBlockDecoration: (decoration) ->
    return unless @observedBlockDecorations.has(decoration)

    @lineTopIndex.removeBlock(decoration.id)
    @observedBlockDecorations.delete(decoration)
    @invalidatedDimensionsByBlockDecoration.delete(decoration)
    @shouldUpdateDecorations = true
    @emitDidUpdateState()

  observeCursor: (cursor) ->
    didChangePositionDisposable = cursor.onDidChangePosition =>
      @pauseCursorBlinking()

      @emitDidUpdateState()

    didChangeVisibilityDisposable = cursor.onDidChangeVisibility =>

      @emitDidUpdateState()

    didDestroyDisposable = cursor.onDidDestroy =>
      @disposables.remove(didChangePositionDisposable)
      @disposables.remove(didChangeVisibilityDisposable)
      @disposables.remove(didDestroyDisposable)

      @emitDidUpdateState()

    @disposables.add(didChangePositionDisposable)
    @disposables.add(didChangeVisibilityDisposable)
    @disposables.add(didDestroyDisposable)

  didAddCursor: (cursor) ->
    @observeCursor(cursor)
    @pauseCursorBlinking()

    @emitDidUpdateState()

  startBlinkingCursors: ->
    unless @isCursorBlinking()
      @state.content.cursorsVisible = true
      @toggleCursorBlinkHandle = setInterval(@toggleCursorBlink.bind(this), @getCursorBlinkPeriod() / 2)

  isCursorBlinking: ->
    @toggleCursorBlinkHandle?

  stopBlinkingCursors: (visible) ->
    if @isCursorBlinking()
      @state.content.cursorsVisible = visible
      clearInterval(@toggleCursorBlinkHandle)
      @toggleCursorBlinkHandle = null

  toggleCursorBlink: ->
    @state.content.cursorsVisible = not @state.content.cursorsVisible
    @emitDidUpdateState()

  pauseCursorBlinking: ->
    @stopBlinkingCursors(true)
    @startBlinkingCursorsAfterDelay ?= _.debounce(@startBlinkingCursors, @getCursorBlinkResumeDelay())
    @startBlinkingCursorsAfterDelay()
    @emitDidUpdateState()

  requestAutoscroll: (position) ->
    @pendingAutoscroll = position
    @shouldUpdateDecorations = true
    @emitDidUpdateState()

  getPendingAutoscroll: ->
    result = {}
    return result unless @pendingAutoscroll?

    {screenRange, options} = @pendingAutoscroll
    @pendingAutoscroll = null

    verticalScrollMarginInPixels = @getVerticalScrollMarginInPixels()
    top = @lineTopIndex.pixelPositionAfterBlocksForRow(screenRange.start.row)
    bottom = @lineTopIndex.pixelPositionAfterBlocksForRow(screenRange.end.row) + @lineHeight
    scrollBottom = @scrollTop + @height

    if options?.center
      desiredScrollCenter = (top + bottom) / 2
      unless @scrollTop < desiredScrollCenter < scrollBottom
        desiredScrollTop = desiredScrollCenter - @height / 2
        desiredScrollBottom = desiredScrollCenter + @height / 2
    else
      desiredScrollTop = top - verticalScrollMarginInPixels
      desiredScrollBottom = bottom + verticalScrollMarginInPixels

    if options?.reversed ? true
      if desiredScrollBottom > scrollBottom
        result.scrollTop = desiredScrollBottom - @height
      if desiredScrollTop < @scrollTop
        result.scrollTop = desiredScrollTop
    else
      if desiredScrollTop < @scrollTop
        result.scrollTop = desiredScrollTop
      if desiredScrollBottom > scrollBottom
        result.scrollTop = desiredScrollBottom - @height

    horizontalScrollMarginInPixels = @getHorizontalScrollMarginInPixels()
    {left} = @pixelRectForScreenRange(new Range(screenRange.start, screenRange.start))
    {left: right} = @pixelRectForScreenRange(new Range(screenRange.end, screenRange.end))
    scrollRight = @scrollLeft + @contentFrameWidth

    desiredScrollLeft = left - horizontalScrollMarginInPixels
    desiredScrollRight = right + horizontalScrollMarginInPixels

    if options?.reversed ? true
      if desiredScrollRight > scrollRight
        result.scrollLeft = desiredScrollRight - @contentFrameWidth
      if desiredScrollLeft < @scrollLeft
        result.scrollLeft = desiredScrollLeft
    else
      if desiredScrollLeft < @scrollLeft
        result.scrollLeft = desiredScrollLeft
      if desiredScrollRight > scrollRight
        result.scrollLeft = desiredScrollRight - @contentFrameWidth

    result

  didChangeFirstVisibleScreenRow: (screenRow) ->
    @setScrollTop(@lineTopIndex.pixelPositionAfterBlocksForRow(screenRow))

  getVerticalScrollMarginInPixels: ->
    Math.round(@model.getVerticalScrollMargin() * @lineHeight)

  getHorizontalScrollMarginInPixels: ->
    Math.round(@model.getHorizontalScrollMargin() * @baseCharacterWidth)

  getVisibleRowRange: ->
    [@startRow, @endRow]

  isRowRendered: (row) ->
    @getStartTileRow() <= row < @getEndTileRow() + @tileSize

  isOpenTagCode: (tagCode) ->
    @displayLayer.isOpenTagCode(tagCode)

  isCloseTagCode: (tagCode) ->
    @displayLayer.isCloseTagCode(tagCode)

  tagForCode: (tagCode) ->
    @displayLayer.tagForCode(tagCode)
