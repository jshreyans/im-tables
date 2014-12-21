_ = require 'underscore'
$ = jQuery = require 'jquery' # Used for overlays
Backbone = require 'backbone'

View = require '../core-view'

Pagination = require './table/pagination'
renderError = require './table/render-error'
NestedTableModel = require '../models/nested-table'
# FIXME - check this import
CellModel = require './models/cell'
# FIXME - check this import
IMObject = require '../models/intermine-object'
# FIXME - check this import
NullObject = require '../models/null-object'
# FIXME - check this import
FPObject = require '../models/fast-path-object'

# Checked imports - they may have their own problems though.
ResultsTable = require './inner'
PageSizer = require './page-sizer'
Page = require '../models/page'
Options = require '../options'
UniqItems = require '../models/uniq-items'
ObjectStore = require '../models/object-store'
TableSummary = require './summary'

# FIXME - check references to this.
NUMERIC_TYPES = ["int", "Integer", "double", "Double", "float", "Float"]

class RowModel extends Backbone.Model # Currently no content.

module.exports = class Table extends View

  className: "im-table-container"

  # @param query The query this view is bound to.
  # @param selector Where to put this table.
  initialize: (@query, @columnHeaders, {start, size} = {}) ->
    super
    @itemModels = new ObjectStore @query
    @_pipe_factor = 10
    @visibleViews = @query.views.slice()

    # columnHeaders contains the header information.
    @columnHeaders ?= new Backbone.Collection
    # rows contains the current rows in the table
    @rows = new Backbone.Collection
    # Formatters we are not allowed to use.
    @blacklistedFormatters = new UniqItems
    # initialise model, making it clear what we expect
    @model.set
      selecting: false
      state: 'FETCHING' # FETCHING, SUCCESS or ERROR
      start: (start ? 0)
      size: (size ? Options.get('DefaultPageSize'))
      count: null,
      lowerBound: null
      upperBound: null
      cache: null
      error: null

    @setFreshness()

    @listenTo @model, 'change:state', @render
    @listenTo @model, 'change:freshness', => @model.set cache: null
    @listenTo @model, 'change:freshness change:start change:size', @fillRows
    @listenTo @model, 'change:cache', => @buildColumnHeaders()
    @listenTo @blacklistedFormatters, 'reset add remove', => @buildColumnHeaders()
    @listenTo @model, 'change:cache', => # Ensure model consistency
      @model.set(lowerBound: null, upperBound: null) unless @model.get('cache')?
    @listenTo @model, 'change:count', => # Previously propagated.
      @query.trigger 'count:is', @data.get 'count'
    @listenTo @model, 'change:error', =>
      err = @model.get 'error'
      @model.set(state: 'ERROR') if err?

    @listenToQuery()
    # Always good to know the API version, but we
    # aren't currently using it for anything.
    @query.service.fetchVersion (error, version) => @model.set {error, version}
    @query.count (error, count) => @model.set {error, count}

    @fillRows().then (-> console.debug 'initial data loaded'), (error) => @model.set {error}
    console.debug 'initialised table'

  FRESHNESS_EVT = 'change:sortorder change:views change:constraints'
  # Ideally we should use fewer events, and more models.
  START_LIST_EVT = 'start:list-creation'
  STOP_LIST_EVT = 'stop:list-creation'
  TABLE_FILL_EVT = 'table:filled'

  listenToQuery: ->
    @listenTo query, FRESHNESS_EVT, @setFreshness
    @listenTo query, START_LIST_EVT, @setSelecting
    @listenTo query, STOP_LIST_EVT, @unsetSelecting
    @listenTo query, TABLE_FILL_EVT, @onDraw

  onDraw: => # Preserve list creation state across pages.
    @query.trigger("start:list-creation") if @model.get 'selecting'

  remove: -> # remove self, and all children, and remove listeners
    @table?.remove() # TODO - use removeChild
    @model.off()
    @itemModels.destroy()
    delete @itemModels
    super # Cleans up listeners attached with @listenTo

  getPage: ->
    {start, size} = @model.toJSON()
    return new Page start, size

  setSelecting: => @model.set selecting: true

  unsetSelecting: => @model.set selecting: false

  canUseFormatter: (formatter) ->
    formatter? and (not @blacklistedFormatters.contains formatter)

  # TODO - move to a separate class for testability.
  buildColumnHeaders: -> @query.service.get("/classkeys").then ({classes}) =>
    q = @query
    # need at least one example row - any will do.
    # if there isn't one, then return and wait to be called later.
    return unless @model.get('cache')?.length
    [row] = @model.get 'cache'
    classKeys = classes
    replacedBy = {}
    {longestCommonPrefix, getReplacedTest} = intermine.utils

    # Create the columns
    cols = for cell in row
      path = q.getPathInfo cell.column
      replaces = if cell.view? # subtable of this cell.
        commonPrefix = longestCommonPrefix cell.view
        path = q.getPathInfo commonPrefix
        replaces = (q.getPathInfo(v) for v in cell.view)
      else
        []
      {path, replaces}

    # Build the replacement information.
    for col in cols when col.path.isAttribute() and intermine.results.shouldFormat col.path
      p = col.path
      formatter = intermine.results.getFormatter p
      
      # Check to see if we should apply this formatter.
      if @canUseFormatter formatter
        col.isFormatted = true
        col.formatter = formatter
        for r in (formatter.replaces ? [])
          subPath = "#{ p.getParent() }.#{ r }"
          replacedBy[subPath] ?= col
          col.replaces.push q.getPathInfo subPath if subPath in q.views

    isKeyField = (col) ->
      return false unless col.path.isAttribute()
      pType = col.path.getParent().getType().name
      fName = col.path.end.name
      return "#{pType}.#{fName}" in (classKeys?[pType] ? [])

    explicitReplacements = {}
    for col in cols
      for r in col.replaces
        explicitReplacements[r] = col

    isReplaced = getReplacedTest replacedBy, explicitReplacements

    newHeaders = for col in cols when not isReplaced col
      if col.isFormatted
        col.replaces.push col.path unless col.path in col.replaces
        col.path = col.path.getParent() if (isKeyField(col) or col.replaces.length > 1)
      col

    @columnHeaders.reset newHeaders

  # Anything that can bust the cache should go in here.
  # As of this point, that just means the state of the query,
  # which can be represented as an (xml) string.
  setFreshness: -> @model.set freshness: @query.toXML()

  ## Filling the rows is a two step process - first we check the row cache to see
  ## if we already have these rows, or update it if not. Only then do we go about
  ## updating the rows collection.
  ## 
  ## Function for buffering data for a request. Each request fetches a page of
  ## pipe_factor * size, and if subsequent requests request data within this range, then
  ##
  ## @param src URL passed from DataTables. Ignored.
  ## @param param list of {name: x, value: y} objects passed from DataTables
  ## @param callback fn of signature: resultSet -> ().
  ##
  ##
  fillRows: ->
    console.debug 'filling rows'
    success = => @model.set state: 'SUCCESS'
    error = (e) => @model.set state: 'ERROR', error: (e ? new Error('unknown error'))
    @updateCache().then(@fillRowsFromCache).then success, error

  updateCache: ->
    console.debug 'updating cache'
    {version, cache, lowerBound, upperBound, start, size} = @model.toJSON()
    end = start + size

    # if stale, cache will be null
    isStale = not cache?

    ## We need new data if the range of this request goes beyond that of the 
    ## cached values, or if all results are selected.
    uncached = (lowerBound < 0) or (start < lowerBound) or (end > upperBound) or (size <= 0)

    # Return a promise to update the cache
    updatingCache = if isStale or uncached
      page = @getRequestPage start, size
      console.debug 'requesting', page

      @overlayTable()
      fetching = @query.tableRows {start: page.start, size: page.size}
      # Always remove the overlay
      fetching.then @removeOverlay, @removeOverlay
      fetching.then (r) => @addRowsToCache page, r
    else
      console.debug 'cache does not need updating'
      jQuery.Deferred(-> @resolve()).promise()

  getRowData: (start, size) => # params, callback) =>

  overlayTable: =>
    return unless @table and @drawn
    elOffset = @$el.offset()
    tableOffset = @table.$el.offset()
    jQuery('.im-table-overlay').remove()
    @overlay = jQuery @make "div",
      class: "im-table-overlay discrete " + Options.get('StylePrefix')
    @overlay.css
        top: elOffset.top
        left: elOffset.left
        width: @table.$el.outerWidth(true)
        height: (tableOffset.top - elOffset.top) + @table.$el.outerHeight()
    @overlay.append @make "h1", {}, "Requesting data..."
    @overlay.find("h1").css
        top: (@table.$el.height() / 2) + "px"
        left: (@table.$el.width() / 4) + "px"
    @overlay.appendTo 'body'
    _.delay (=> @overlay.removeClass "discrete"), 100

  removeOverlay: => @overlay?.remove()

  ##
  ## Get the page to request given the desired start and size.
  ##
  ## @param start the index of the first result the user actually wants to see.
  ## @param size The size of the dislay window.
  ##
  ## @return A page object with "start" and "size" properties set to include the desired
  ##         results, but also taking the cache into account.
  ##
  getRequestPage: ->
    {start, size, cache, lowerBound, upperBound} = @model.toJSON()
    page = new Page(start, size)
    unless cache
      ## Can ignore the cache
      page.size *= @_pipe_factor
      return page

    # When paging backwards - extend page towards 0.
    if start < lowerBound
        page.start = Math.max 0, start - (size * @_pipe_factor)

    if size > 0
        page.size *= @_pipe_factor
    else
        page.size = '' # understood by server as all.

    # Don't permit gaps, if the query itself conforms with the cache.
    if page.size && (page.end() < lowerBound)
      if (lowerBound - page.end()) > (page.size * @_pipe_factor)
        @model.unset 'cache'
        page.size *= 2
        return page
      else
        page.size = lowerBound - page.start

    if upperBound < page.start
      if (page.start - upperBound) > (page.size * 10)
        @model.unset 'cache'
        page.size *= 2
        page.start = Math.max(0, page.start - (size * @_pipe_factor))
        return page
      if page.size
        page.size += page.start - upperBound
      # Extend towards cache limit
      page.start = upperBound

    return page

  ##
  ## Update the cache with the retrieved results. If there is an overlap 
  ## between the returned results and what is already held in cache, prefer the newer 
  ## results.
  ##
  ## @param page The page these results were requested with.
  ## @param rows The rows returned from the server.
  ##
  addRowsToCache: (page, rows) ->
    # {cache :: [], lowerBound :: int, upperBound :: int}
    {cache, lowerBound, upperBound} = @model.toJSON()
    if cache? # may not exist yet.
      cache = cache.slice()
      # Add rows we don't have to the front
      if page.start < lowerBound
          cache = rows.concat cache.slice page.end() - lowerBound
      # Add rows we don't have to the end
      if upperBound < page.end() or page.all()
          cache = cache.slice(0, (page.start - lowerBound)).concat(rows)

      lowerBound = Math.min lowerBound, page.start
      upperBound = lowerBound + cache.length
    else
      cache = rows.slice()
      lowerBound = page.start
      upperBound = page.end()

    @model.set {cache, lowerBound, upperBound}

  makeCellModel: (obj) =>
    objects = @itemModels
    cm = if _.has(obj, 'rows')
      node = @query.getPathInfo obj.column
      # Here we lift some properties to more useful types
      new NestedTableModel _.extend {}, obj,
        node: node # Duplicate name - not necessary?
        column: node 
        rows: (r.map(@makeCellModel) for r in obj.rows)
    else
      column = @query.getPathInfo(obj.column)
      node = column.getParent()
      field = obj.column.replace(/^.*\./, '')
      model = if obj.id?
        objects.get obj, field
      else if not obj.class?
        type = node.getParent().name
        new NullObject {}, {@query, field, type}
      else # FastPathObjects don't have ids, and cannot be in lists.
        new FPObject({}, {@query, obj, field})
      # Do we need to do a merge here? - llok at NullObject and FPO
      new CellModel
        query: @query # TODO - stop passing the query around!
        cell: model
        node: node
        column: column
        field: field
        value: obj.value
    return cm

  ##
  ## Populate the rows collection with the current rows from cache.
  ## This requires that the cache has been populated, so should only
  ## be called from `::fillRows`
  ##
  ## @param echo The results table request control.
  ## @param start The index of the first result desired.
  ## @param size The page size
  ##
  fillRowsFromCache: =>
    console.debug 'filling rows from cache'
    {cache, lowerBound, start, size} = @model.toJSON()
    if not cache?
      return console.error 'Cache is not filled'
    base = @query.service.root.replace /\/service\/?$/, ""
    rows = cache.slice()
    # Splice off the undesired sections.
    rows.splice(0, start - lowerBound)
    rows.splice(size, rows.length) if (size > 0)

    # FIXME - make sure cells know their node...

    fields = ([@query.getPathInfo(v).getParent(), v.replace(/^.*\./, "")] for v in @query.views)

    @rows.reset rows.map (row) =>
      new RowModel cells: row.map (cell, idx) => @makeCellModel cell

    console.debug 'rows filled', @rows.size()

  makeTable: -> @make 'table',
    class: "table table-striped table-bordered"
    width: "100%"

  renderFetching: ->
    """
      <h2>Building table</h2>
      <div class="progress progress-striped active progress-info">
          <div class="bar" style="width: 100%"></div>
      </div>
    """

  renderError: -> renderError @query, @model.get('error')

  renderTable: ->
    frag = document.createDocumentFragment()
    $widgets = $('<div>').appendTo frag
    for component in Options.get('TableWidgets', []) when "place#{ component }" of @
      method = "place#{ component }"
      @[ method ]( $widgets )
    $widgets.append """<div style="clear:both"></div>"""

    tel = @makeTable()
    frag.appendChild tel

    @table = new ResultsTable @query, @blacklistedFormatters, @columnHeaders, @rows
    @table.setElement tel
    @table.render()

    return frag

  render: ->
    @table?.remove()
    state = @model.get('state')

    if state is 'FETCHING'
      console.debug 'state is fetching'
      @$el.html @renderFetching()
    else if state is 'ERROR'
      console.debug 'state is error'
      @$el.html @renderError()
    else
      console.debug 'state is success'
      @$el.html @renderTable()

  renderChild: (name, container, Child) ->
    console.debug "placing #{ name }"
    child = new Child {@model}
    @children[name]?.remove()
    @children[name] = child
    child.render()
    child.$el.appendTo container

  placePagination: ($widgets) ->
    @renderChild 'pagination', $widgets, Pagination

  placePageSizer: ($widgets) ->
    @renderChild 'pagesizer', $widgets, PageSizer

  placeTableSummary: ($widgets) ->
    @renderChild 'tablesummary', $widgets, TableSummary

  # FIXME - check references
  getCurrentPageSize: -> @model.get 'size'

  # FIXME - check references
  getCurrentPage: () ->
    {start, size} = @model.toJSON()
    if size then Math.floor(start / size) else 0

