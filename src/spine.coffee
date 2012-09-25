Events =
  bind: (ev, callback) ->
    evs   = ev.split(' ')
    calls = @hasOwnProperty('_callbacks') and @_callbacks or= {}

    for name in evs
      calls[name] or= []
      calls[name].push(callback)
    this

  one: (ev, callback) ->
    @bind ev, ->
      @unbind(ev, arguments.callee)
      callback.apply(this, arguments)

  trigger: (args...) ->
    ev = args.shift()

    list = @hasOwnProperty('_callbacks') and @_callbacks?[ev]
    return unless list

    for callback in list
      if callback.apply(this, args) is false
        break
    true

  unbind: (ev, callback) ->
    unless ev
      @_callbacks = {}
      return this

    list = @_callbacks?[ev]
    return this unless list

    unless callback
      delete @_callbacks[ev]
      return this

    for cb, i in list when cb is callback
      list = list.slice()
      list.splice(i, 1)
      @_callbacks[ev] = list
      break
    this

Log =
  trace: true

  logPrefix: '(App)'

  log: (args...) ->
    return unless @trace
    if @logPrefix then args.unshift(@logPrefix)
    console?.log?(args...)
    this

moduleKeywords = ['included', 'extended']

class Module
  @include: (obj) ->
    throw new Error('include(obj) requires obj') unless obj
    for key, value of obj when key not in moduleKeywords
      @::[key] = value
    obj.included?.apply(this)
    this

  @extend: (obj) ->
    throw new Error('extend(obj) requires obj') unless obj
    for key, value of obj when key not in moduleKeywords
      @[key] = value
    obj.extended?.apply(this)
    this

  @proxy: (func) ->
    => func.apply(this, arguments)

  proxy: (func) ->
    => func.apply(this, arguments)

  constructor: ->
    @init?(arguments...)

class Model extends Module
  @extend Events

  @configure: ->
    return if @hasOwnProperty('configured')
    @configured = true

    @records     = []
    @irecords    = {}
    @crecords    = {}
    @attributes  = {}
    @unbind()
    this

  @key: (name, type, options = {}) ->
    @configure()

    if typeof type is 'object'
      [options, type] = [type, null]

    serialize =
      switch type
        when String, Boolean, null, undefined
          (val) -> val
        when Number
          parseFloat
        when Date
          (val) -> new type(val)
        else
          type

    @attributes[name] =
      type:      type
      serialize: serialize
      options:   options

  @toString: -> "#{@name}(#{keys(@attributes).join(", ")})"

  @find: (id) ->
    record = @irecords[id]
    if !record and ("#{id}").match(/c-\d+/)
      return @findCID(id)
    throw new Error('Unknown record') unless record
    record.clone()

  @findCID: (cid) ->
    record = @crecords[cid]
    throw new Error('Unknown record') unless record
    record.clone()

  @exists: (id) ->
    try
      return @find(id)
    catch e
      return false

  @refresh: (values, options = {}) ->
    if options.clear
      @records  = []
      @irecords = {}
      @crecords = {}

    records = @fromJSON(values)
    records = [records] unless isArray(records)

    for record in records
      record.id           or= record.cid
      @records.push(record)
      @irecords[record.id]  = record
      @crecords[record.cid] = record

    @sort()

    result = @cloneArray(records)
    @trigger('refresh', result)
    result

  @select: (callback) ->
    (record.clone() for record in @records when callback(record))

  @findByAttribute: (name, value) ->
    for record in @records
      if record[name] is value
        return record.clone()
    null

  @findAllByAttribute: (name, value) ->
    @select (item) ->
      item[name] is value

  @each: (callback) ->
    for record in @records
      callback(value.clone())

  @all: ->
    @cloneArray(@records)

  @first: ->
    @records[0]?.clone()

  @last: ->
    values = @records()
    record = values[values.length - 1]
    record?.clone()

  @count: ->
    @records.length

  @deleteAll: ->
    @records  = []
    @irecords = {}
    @crecords = {}

  @destroyAll: ->
    for record in @records
      record.destroy()

  @update: (id, atts, options) ->
    @find(id).updateAttributes(atts, options)

  @create: (atts, options) ->
    record = new @(atts)
    record.save(options)

  @destroy: (id, options) ->
    @find(id).destroy(options)

  @change: (callbackOrParams) ->
    if typeof callbackOrParams is 'function'
      @bind('change', callbackOrParams)
    else
      @trigger('change', callbackOrParams)

  @toJSON: -> @records

  @fromJSON: (objects) ->
    return unless objects
    if typeof objects is 'string'
      objects = JSON.parse(objects)
    if isArray(objects)
      (new @(value) for value in objects)
    else
      new @(objects)

  @fromForm: ->
    (new this).fromForm(arguments...)

  @isInstance: (object) ->
    typeof object is 'object' and object instanceof this

  @sort: ->
    if @comparator
      @records.sort (args...) =>
        @comparator(args...)
    @records

  # Private

  @cloneArray: (array) ->
    (value.clone() for value in array)

  @idCounter: 0

  @uid: (prefix = '') ->
    uid = prefix + @idCounter++
    uid = @uid(prefix) if @exists(uid)
    uid

  # Instance

  constructor: (atts) ->
    # Return object if it's already an instance
    if @constructor.isInstance(atts)
      return atts

    super
    @load atts if atts
    @cid = @constructor.uid('c-')

  isNew: ->
    not @exists()

  isValid: ->
    not @validate()

  validate: ->
    valid  = true
    result = {}

    for attr, value of @constructor.attributes
      if value.options.required and !@[attr]
        valid = false
        result[attr] =
          type:    'required'
          message: "#{attr} required"

    result unless valid

  load: (attrs) ->
    for key, value of attrs
      if typeof @[key] is 'function'
        @[key](value)
      else if attr = @constructor.attributes[key]
        @[key] = attr.serialize(value)
      else
        @[key] = value
    this

  attributes: ->
    result = {}
    for key of @constructor.attributes when key of this
      if typeof @[key] is 'function'
        result[key] = @[key]()
      else
        result[key] = @[key]
    result.id = @id if @id
    result

  eql: (rec) ->
    !!(rec and rec.constructor is @constructor and
        (rec.cid is @cid) or (rec.id and rec.id is @id))

  save: (options = {}) ->
    unless options.validate is false
      error = @validate()
      if error
        @trigger('error', error)
        return false

    @trigger('beforeSave', options)
    record = if @isNew() then @create(options) else @update(options)
    @trigger('save', options)
    record

  updateAttribute: (name, value, options) ->
    @[name] = value
    @save(options)

  updateAttributes: (atts, options) ->
    @load(atts)
    @save(options)

  changeID: (id) ->
    records = @constructor.irecords
    records[id] = records[@id]
    delete records[@id]
    @id = id
    @save()

  dup: (newRecord) ->
    result = new @constructor(@attributes())
    if newRecord is false
      result.cid = @cid
    else
      delete result.id
    result

  clone: ->
    createObject(this)

  reload: ->
    return this if @isNew()
    original = @constructor.find(@id)
    @load(original.attributes())
    original

  toJSON: ->
    @attributes()

  toString: ->
    "<#{@constructor.name} (#{JSON.stringify(this)})>"

  fromForm: (form) ->
    result = {}
    for key in $(form).serializeArray()
      result[key.name] = key.value
    @load(result)

  exists: ->
    @id and @id of @constructor.irecords

  destroy: (options = {}) ->
    @trigger('beforeDestroy', options)

    # Remove record from model
    records = @constructor.records.slice()
    for record in records when record is this
      records.splice(i, 1)
      break
    @constructor.records = records

    # Remove ID and CID
    delete @constructor.irecords[@id]
    delete @constructor.crecords[@cid]

    @destroyed = true
    @trigger('destroy', options)
    @trigger('change', 'destroy', options)
    @unbind()
    this

  # Private

  update: (options) ->
    @trigger('beforeUpdate', options)

    records = @constructor.irecords
    records[@id].load @attributes()

    @constructor.sort()

    clone = records[@id].clone()
    clone.trigger('update', options)
    clone.trigger('change', 'update', options)
    clone

  create: (options) ->
    @trigger('beforeCreate', options)
    @id          = @cid unless @id

    record       = @dup(false)
    @constructor.records.push(record)
    @constructor.irecords[@id]  = record
    @constructor.crecords[@cid] = record

    @constructor.sort()

    clone        = record.clone()
    clone.trigger('create', options)
    clone.trigger('change', 'create', options)
    clone

  bind: (events, callback) ->
    @constructor.bind events, binder = (record) =>
      if record and @eql(record)
        callback.apply(this, arguments)
    @constructor.bind 'unbind', unbinder = (record) =>
      if record and @eql(record)
        @constructor.unbind(events, binder)
        @constructor.unbind('unbind', unbinder)
    binder

  one: (events, callback) ->
    binder = @bind events, =>
      @constructor.unbind(events, binder)
      callback.apply(this, arguments)

  trigger: (args...) ->
    args.splice(1, 0, this)
    @constructor.trigger(args...)

  unbind: ->
    @trigger('unbind')

class Controller extends Module
  @include Events
  @include Log

  eventSplitter: /^(\S+)\s*(.*)$/
  tag: 'div'

  constructor: (options) ->
    @options = options

    for key, value of @options
      @[key] = value

    @el  = document.createElement(@tag) unless @el
    @$el = $(@el)

    @$el.addClass(@className) if @className
    @$el.attr(@attributes) if @attributes

    @events = @constructor.events unless @events
    @elements = @constructor.elements unless @elements

    @delegateEvents() if @events
    @refreshElements() if @elements

    super

  release: =>
    @trigger 'release'
    @$el.remove()
    @unbind()

  $: (selector) -> $(selector, @$el)

  delegateEvents: (events = @events) ->
    for key, method of events

      if typeof(method) is 'function'
        # Always return true from event handlers
        method = do (method) => =>
          method.apply(this, arguments)
          true
      else
        unless @[method]
          throw new Error("#{method} doesn't exist")

        method = do (method) => =>
          @[method].apply(this, arguments)
          true

      match      = key.match(@eventSplitter)
      eventName  = match[1]
      selector   = match[2]

      if selector is ''
        @$el.bind(eventName, method)
      else
        @$el.delegate(selector, eventName, method)

  refreshElements: ->
    for key, value of @elements
      @[value] = @$(key)

  delay: (func, timeout) ->
    setTimeout(@proxy(func), timeout || 0)

  html: (element) ->
    @$el.html(element.el or element)
    @refreshElements()
    @$el

  append: (elements...) ->
    elements = (e.el or e for e in elements)
    @$el.append(elements...)
    @refreshElements()
    @$el

  appendTo: (element) ->
    @$el.appendTo(element.el or element)
    @refreshElements()
    @$el

  prepend: (elements...) ->
    elements = (e.el or e for e in elements)
    @$el.prepend(elements...)
    @refreshElements()
    @$el

  replace: (element) ->
    [previous, @$el] = [@$el, element.el or element]

    @$el = $(@$el)
    @el  = @$el.get(0)
    @$el.replaceAll(previous)

    @delegateEvents()
    @refreshElements()
    @$el

# Utilities & Shims

$ = window?.jQuery or window?.Zepto or (element) -> element

createObject = Object.create or (o) ->
  Func = ->
  Func.prototype = o
  new Func()

isArray = (value) ->
  Object::toString.call(value) is '[object Array]'

isBlank = (value) ->
  return true unless value
  return false for key of value
  true

makeArray = (args) ->
  Array::slice.call(args, 0)

keys = Object.keys or (object) ->
  (key for key, value of object)

# Globals

Spine = @Spine   = {}
module?.exports  = Spine

Spine.version    = '1.0.9'
Spine.isArray    = isArray
Spine.isBlank    = isBlank
Spine.$          = $
Spine.Events     = Events
Spine.Log        = Log
Spine.Module     = Module
Spine.Controller = Controller
Spine.Model      = Model

# Global events

Module.extend.call(Spine, Events)

# JavaScript compatability

Module.create = Module.sub =
  Controller.create = Controller.sub =
    Model.sub = (instances, statics) ->
      class result extends this
      result.include(instances) if instances
      result.extend(statics) if statics
      result.unbind?()
      result

Model.setup = (name, attributes = []) ->
  class Instance extends this
  Instance.configure(name, attributes...)
  Instance

Spine.Class = Module