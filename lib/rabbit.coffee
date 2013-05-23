{EventEmitter} = require 'events'

async = require 'async'
jsdom = require 'jsdom'
request = require 'request'
phantom = require 'node-phantom'

class Rabbit extends EventEmitter

  # Steps
  # 1. find what environment the target is in
  # 2. grab requested data from ouroboros
  # 3. grab page html
  # 4. Plop requested data onto page
  # 5. Save html back to bucket
  # 6. ...
  # 7. profit

  project: ''
  bucket: ''
  file: 'index.html'
  types: ['project']

  options: null

  constructor: (params = {}) ->
    @[property] = value for own property, value of params when property of @

    # S3
    @s3 = require('knox').createClient
      key: @options.key || process.env.S3_ACCESS_ID
      secret: @options.secret || process.env.S3_SECRET_KEY
      bucket: @bucket

    # To make the async part prettier
    @host = ''
    @rawHtml = ''
    @dataResults = {}
    @loadedHtml = ''

  prefetch: =>
    async.auto
      getHost: @getHost
      getData: ['getHost', @getData]
      getHtml: ['getHost', @getHtml]
      insertData: ['getHtml', 'getData', @insertData]
      save: ['insertData', @save]

  getHost: (callback) =>
    phantom.create (err, ph) =>
      ph.createPage (err, page) =>
        page.open @url(), (err, status) =>
          if err
            ph.exit()
            callback err, null
            return

          page.evaluate ->
            return window.zooniverse.Api.current.proxyFrame.host
          , (err, @host) ->
            ph.exit()

            if err
              callback err, null
              return

            callback null, @host

  getData: (callback) =>
    funcList = {}

    for dataType in @types
      do (dataType) =>
        funcList[dataType] = (callback) =>
          @_queryApi dataType, callback

    async.parallel funcList, (err, res) ->
      callback err, null if err
      callback null, res

  getHtml: (callback) =>
    @s3.getFile @file, (err, res) =>
      callback err, null if err

      @rawHtml = ''

      res.on 'data', (chunk) =>
        @rawHtml += chunk

      res.on 'end', =>
        callback null, @rawHtml

  insertData: (callback) =>
    jsdom.env @rawHtml, (err, window) =>
      callback err, null if err

      document = window.document

      for key, datum of @dataResults
        keyId = key.replace '_', '-'
        projectEl = document.querySelector "script#define-zooniverse-#{ keyId }"

        if projectEl?
          projectEl.innerHTML = @_template key, datum
        else
          scriptTag = document.createElement 'script'
          scriptTag.setAttribute 'type', 'text/javascript'
          scriptTag.id = "define-zooniverse-#{ keyId }"
          scriptTag.innerHTML = @_template key, datum

          firstScript = document.body.querySelector('script')
          document.body.insertBefore scriptTag, firstScript

      @loadedHtml = document.documentElement.outerHTML
      callback null, @loadedHtml

  save: (callback) =>
    buffer = new Buffer @loadedHtml

    headers =
      'x-amz-acl': 'public-read'
      'Content-Type': 'text/html'

    @s3.putBuffer buffer, @file, headers, (err, res) ->
      callback null, res

  _queryApi: (type, callback) =>
    dataTypes =
      project:
        endpoint: "/projects/#{ @project }"
      project_groups:
        endpoint: "/projects/#{ @project }/groups"

    request.get @host + dataTypes[type].endpoint, (err, res, body) =>
      if not err and res.statusCode is 200
        @dataResults[type] = body
        callback null, @dataResults[type]
      else
        callback err, null

  _template: (dataType, data) =>
    "window.DEFINE_ZOONIVERSE_#{ dataType.toUpperCase() } = #{ data }"  

  _url: =>
    # Attempt to derive the url from the bucket
    if @bucket is 'zooniverse-demo'
      "http://zooniverse-demo.s3-website-us-east-1.amazonaws.com"
    else
      "http://#{ @bucket }"

module.exports = Rabbit