crypto = require 'crypto'
fs = require 'fs'
http = require 'http'
net = require 'net'
os = require 'os'
path = require 'path'
querystring = require 'querystring'
url = require 'url'
{BufferedProcess} = require 'atom'

debug = require './debug'

ycmdPath = path.resolve atom.packages.resolvePackagePath('you-complete-me'), 'ycmd'
ycmdProcess = null
port = null
hmacSecret = null

launch = ->
  findUnusedPort = new Promise (fulfill, reject) ->
    net.createServer()
      .listen 0, () ->
        result = this.address().port
        this.close()
        fulfill result
      .on 'error', (error) ->
        reject error

  generateRandomSecret = new Promise (fulfill, reject) ->
    crypto.randomBytes 16, (error, data) ->
      unless error?
        fulfill data
      else
        reject error

  readDefaultOptions = new Promise (fulfill, reject) ->
    defaultOptionsFile = path.resolve ycmdPath, 'ycmd', 'default_settings.json'
    fs.readFile defaultOptionsFile, encoding: 'utf8', (error, data) ->
      unless error?
        fulfill JSON.parse data
      else
        reject error

  processData = ([unusedPort, randomSecret, options]) -> new Promise (fulfill, reject) ->
    port = unusedPort
    hmacSecret = randomSecret
    options.hmac_secret = hmacSecret.toString 'base64'
    options.global_ycm_extra_conf = atom.config.get 'you-complete-me.globalExtraConfig'
    optionsFile = path.resolve os.tmpdir(), "AtomYcmOptions-#{Date.now()}"
    fs.writeFile optionsFile, JSON.stringify(options), encoding: 'utf8', (error) ->
      unless error?
        fulfill optionsFile
      else
        reject error

  startServer = (optionsFile) -> new Promise (fulfill, reject) ->
    parameters =
      command: atom.config.get 'you-complete-me.pythonExecutable'
      args: [
        path.resolve ycmdPath, 'ycmd'
        "--port=#{port}"
        "--options_file=#{optionsFile}"
        '--idle_suicide_seconds=600'
      ]
      options: {}
      exit: (status) -> ycmdProcess = null
    parameters.stdout = (output) -> debug.log 'CONSOLE', output
    parameters.stderr = (output) -> debug.log 'CONSOLE', output
    ycmdProcess = new BufferedProcess parameters
    fulfill()

  Promise.all [findUnusedPort, generateRandomSecret, readDefaultOptions]
    .then processData
    .then startServer

prepare = ->
  if ycmdProcess?.killed is false
    Promise.resolve()
  else
    launch()

reset = ->
  ycmdProcess?.kill()
  ycmdProcess = null
  port = null
  hmacSecret = null
  Promise.resolve()

request = (method, endpoint, parameters = null) -> prepare().then ->
  generateHmac = (data, encoding) ->
    crypto.createHmac('sha256', hmacSecret).update(data).digest(encoding)

  verifyHmac = (data, hmac, encoding) ->
    secureCompare generateHmac(data, encoding), hmac

  secureCompare = (string1, string2) ->
    return false unless typeof string1 is 'string' and typeof string2 is 'string'
    return false unless string1.length is string2.length
    return Buffer.compare(generateHmac(string1), generateHmac(string2)) is 0

  signMessage = (message, payload) ->
    message.headers['X-Ycm-Hmac'] = generateHmac Buffer.concat([generateHmac(message.method), generateHmac(message.path), generateHmac(payload)]), 'base64'

  verifyMessage = (message, payload) ->
    verifyHmac payload, message.headers['x-ycm-hmac'], 'base64'

  unicodeEscaper = (key, value) ->
    if typeof value is 'string'
      escapedString = ''
      for i in [0...value.length]
        char = value.charAt i
        charCode = value.charCodeAt i
        escapedString += if charCode < 0x80 then char else "\\u#{"0000#{charCode.toString 16}".substr -4}"
      return escapedString
    else
      return value

  Promise.resolve()
    .then () ->
      requestMessage =
        hostname: 'localhost'
        port: port
        method: method
        path: url.resolve '/', endpoint
        headers: {}
      isPost = method is 'POST'
      requestPayload = ''
      if isPost
        requestPayload = JSON.stringify parameters, unicodeEscaper if parameters?
        requestMessage.headers['Content-Type'] = 'application/json'
        requestMessage.headers['Content-Length'] = requestPayload.length
      else
        requestMessage.path += "?#{querystring.stringify parameters}" if parameters?
      signMessage requestMessage, requestPayload
      return [requestMessage, isPost, requestPayload]

    .then ([requestMessage, isPost, requestPayload]) -> new Promise (fulfill, reject) ->
      requestHandler = http.request requestMessage, (responseMessage) ->
        responseMessage.setEncoding 'utf8'
        responsePayload = ''
        responseMessage.on 'data', (chunk) -> responsePayload += chunk
        responseMessage.on 'end', () ->
          if verifyMessage responseMessage, responsePayload
            responseObject = JSON.parse responsePayload
            debug.log 'REQUEST', method, endpoint, parameters
            debug.log 'RESPONSE', responseObject
            fulfill responseObject
          else
            reject new Error 'Bad Hmac'
      requestHandler.on 'error', (error) -> reject error
      requestHandler.write requestPayload if isPost
      requestHandler.end()

# API Endpoints:
#
# GET /ready
# GET /healthy
#
# POST /semantic_completion_available
# POST /completions
# POST /detailed_diagnostic
# POST /event_notification
#
# POST /defined_subcommands
# POST /run_completer_command
#
# GET /user_options
# POST /user_options
# POST /load_extra_conf_file
# POST /ignore_extra_conf_file
#
# POST /debug_info
#
# Only available on Qusic's ycmd fork:
# POST /atom_completions

module.exports =
  prepare: prepare
  reset: reset
  request: request
