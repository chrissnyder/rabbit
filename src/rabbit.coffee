async = require 'async'
AWS = require 'aws-sdk'
jsdom = require 'jsdom'
request = require 'request'
url = require 'url'

class Rabbit

  project: ''
  bucket: ''

  host: 'https://api.zooniverse.org'

  file: 'index.html'
  types: ['project']

  options: {}

  constructor: (params = {}) ->
    @[property] = value for own property, value of params when property of @

    # S3
    @s3 ?= new AWS.S3
      accessKeyId: @options.key || process.env.AMAZON_ACCESS_KEY_ID
      secretAccessKey: @options.secret || process.env.AMAZON_SECRET_ACCESS_KEY
      region: @options.region || 'us-east-1'

    # To make the async part prettier
    @rawHtml = ''
    @dataResults = {}
    @loadedHtml = ''

    @createEndpoints()

  go: =>
    async.auto
      getData: @getData
      getHtml: @getHtml
      insertData: ['getHtml', 'getData', @insertData]
      save: ['insertData', @save]
    , (err) =>
      if err?
        console.log err

      console.log "Prefetched #{ @project }"

  getData: (callback) =>
    funcList = {}

    for dataType in @types
      do (dataType) =>
        funcList[dataType] = (callback) =>
          @queryApi dataType, callback

    async.parallel funcList, (err, res) ->
      if err
        callback err, null
      else
        callback null, res

  getHtml: (callback) =>
    @s3.getObject
      Bucket: @bucket
      Key: @file
      (err, res) =>
        if err
          callback err, null
          return

        @rawHtml = res.Body.toString()
        callback null, @rawHtml

  insertData: (callback) =>
    jsdom.env @rawHtml, (err, window) =>
      if err
        callback err, null
        return

      document = window.document

      # Start fresh each time
      dataEls = document.querySelectorAll "script[id^=define-zooniverse-]"
      dataEls[i]?.parentNode.removeChild(dataEls[i]) for i in [0..dataEls.length - 1]

      for key, datum of @dataResults
        keyId = key.replace '_', '-'

        scriptTag = document.createElement 'script'
        scriptTag.setAttribute 'type', 'text/javascript'
        scriptTag.id = "define-zooniverse-#{ keyId }"
        scriptTag.innerHTML = @template key, datum

        firstScript = document.body.querySelector('script')

        if firstScript
          document.body.insertBefore scriptTag, firstScript
        else
          document.head.insertBefore scriptTag, document.head.firstChild

      @loadedHtml = document.documentElement.outerHTML
      callback null, @loadedHtml

  save: (callback) =>
    buffer = new Buffer @loadedHtml

    @s3.putObject
      Bucket: @bucket
      Key: @file
      ACL: 'public-read'
      Body: buffer
      ContentType: 'text/html'
      (err, res) ->
        if err
          callback err, null
          return

        callback null, res

  queryApi: (type, callback) =>
    requestUrl = url.resolve @host, @endpoints[type].endpoint

    request.get requestUrl, { strictSSL: false }, (err, res, body) =>
      if not err and res.statusCode is 200
        @dataResults[type] = body
        callback null, @dataResults[type]
      else
        callback err, null

  template: (dataType, data) =>
    "window.DEFINE_ZOONIVERSE_#{ dataType.toUpperCase() } = #{ data }"  

  bucketUrl: =>
    # Attempt to derive the url from the bucket
    if @bucket is 'zooniverse-demo'
      url.resolve "http://zooniverse-demo.s3-website-us-east-1.amazonaws.com/", @file
    else
      url.resolve "http://#{ @bucket }", @file

  createEndpoints: =>
    # Short of somehow having a service that returns Ouroboros
    # endpoints, I don't know how else to do this.
    @endpoints =
      project:
        endpoint: "/projects/#{ @project }"
      project_groups:
        endpoint: "/projects/#{ @project }/groups"

module.exports = Rabbit
