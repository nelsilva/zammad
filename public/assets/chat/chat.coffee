do($ = window.jQuery, window) ->

  # Define the plugin class
  class ZammadChat

    defaults:
      invitationPhrase: '<strong>Chat</strong> with us!'
      agentPhrase: ' is helping you'
      show: true
      target: $('body')

    _messageCount: 0
    isOpen: false
    blinkOnlineInterval: null
    stopBlinOnlineStateTimeout: null
    showTimeEveryXMinutes: 1
    lastTimestamp: null
    lastAddedType: null
    inputTimeout: null
    isTyping: false
    isOnline: true
    debug: true
    host: 'ws://localhost:6042'
    strings:
      'Online': 'Online'
      'Offline': 'Offline'
      'Connecting': 'Verbinden'
      'Connection re-established': 'Connection re-established'
      'Today': 'Heute'
      'Send': 'Senden'
      'Compose your message...': 'Ihre Nachricht...'
      'All colleges are busy.': 'Alle Kollegen sind belegt.'
      'You are on waiting list position <strong>%s</strong>.': 'Sie sind in der Warteliste an der Position <strong>%s</strong>.'
      '': ''
      '': ''
      '': ''

    T: (string, items...) =>
      if !@strings[string]
        @log 'notice', "Translation needed for '#{string}'"
      translation = @strings[string] || string
      if items
        for item in items
          translation = translation.replace(/%s/, item)

      translation

    log: (level, string...) =>
      return if !@debug && level is 'debug'
      console.log level, string

    view: (name) =>
      return (options) =>
        if !options
          options = {}

        options.T = @T
        return window.zammadChatTemplates[name](options)

    constructor: (el, options) ->
      @options = $.extend {}, @defaults, options
      @el = $(@view('chat')(@options))
      @options.target.append @el

      @el.find('.js-chat-open').click @open
      @el.find('.js-chat-close').click @close
      @el.find('.zammad-chat-controls').on 'submit', @onSubmit
      @el.find('.zammad-chat-input').on
        keydown: @checkForEnter
        input: @onInput

      @session_id = undefined

      if !window.WebSocket
        @log 'notice', 'Chat: Browser not supported!'
        return

      @connect()

      @onReady()

    checkForEnter: (event) =>
      if not event.shiftKey and event.keyCode is 13
        event.preventDefault()
        @sendMessage()

    send: (event, data) =>
      @log 'debug', 'ws:send', event, data
      pipe = JSON.stringify
        event: event
        data: data
      @ws.send pipe

    onWebSocketMessage: (e) =>
      pipes = JSON.parse( e.data )
      @log 'debug', 'ws:onmessage', pipes

      for pipe in pipes
        switch pipe.event
          when 'chat_session_message'
            return if pipe.data.self_written
            @receiveMessage pipe.data
          when 'chat_session_typing'
            return if pipe.data.self_written
            @onAgentTypingStart()
          when 'chat_session_start'
            switch pipe.data.state
              when 'ok'
                @onConnectionEstablished pipe.data.agent
          when 'chat_session_init'
            switch pipe.data.state
              when 'ok'
                @onConnectionEstablished pipe.data.agent
              when 'queue'
                @onQueue pipe.data.position
                @session_id = pipe.data.session_id
          when 'chat_session_closed'
            @onSessionClosed pipe.data
          when 'chat_session_left'
            @onSessionClosed pipe.data
          when 'chat_status_customer'
            switch pipe.data.state
              when 'online'
                @onReady()
                @log 'debug', 'Zammad Chat: ready'
              when 'offline'
                @log 'debug', 'Zammad Chat: No agent online'
              when 'chat_disabled'
                @log 'debug', 'Zammad Chat: Chat is disabled'
              when 'no_seats_available'
                @log 'debug', 'Zammad Chat: Too many clients in queue. Clients in queue: ', pipe.data.queue

    onReady: =>
      if @options.show
        @show()
        @el.find('.zammad-chat-input').autoGrow
          extraLine: false

    onInput: =>
      # remove unread-state from messages
      @el.find('.zammad-chat-message--unread')
        .removeClass 'zammad-chat-message--unread'

      @onTypingStart()

    onTypingStart: ->

      clearTimeout(@isTypingTimeout) if @isTypingTimeout

      # fire typingEnd after 5 seconds
      @isTypingTimeout = setTimeout @onTypingEnd, 1500

      # send typing start event
      if !@isTyping
        @isTyping = true
        @send 'chat_session_typing', {session_id: @session_id}

    onTypingEnd: =>
      @isTyping = false

    onSubmit: (event) =>
      event.preventDefault()
      @sendMessage()

    sendMessage: ->
      message = @el.find('.zammad-chat-input').val()

      return if !message

      messageElement = @view('message')
        message: message
        from: 'customer'
        id: @_messageCount++

      @maybeAddTimestamp()

      # add message before message typing loader
      if @el.find('.zammad-chat-message--typing').size()
        @lastAddedType = 'typing-placeholder'
        @el.find('.zammad-chat-message--typing').before messageElement
      else
        @lastAddedType = 'message--customer'
        @el.find('.zammad-chat-body').append messageElement

      @el.find('.zammad-chat-input').val('')
      @scrollToBottom()

      @isTyping = false

      # send message event
      @send 'chat_session_message',
        content: message
        id: @_messageCount
        session_id: @session_id

    receiveMessage: (data) =>
      # hide writing indicator
      @onAgentTypingEnd()

      @maybeAddTimestamp()

      @lastAddedType = 'message--agent'
      unread = document.hidden ? " zammad-chat-message--unread" : ""
      @el.find('.zammad-chat-body').append @view('message')
        message: data.message.content
        id: data.id
        from: 'agent'
      @scrollToBottom()

    open: =>
      return if @isOpen

      @showLoader()

      @el
        .addClass('zammad-chat-is-open')
        .animate { bottom: 0 }, 500, @onOpenAnimationEnd

      @isOpen = true

    onOpenAnimationEnd: =>
      #setTimeout @onQueue, 1180
      # setTimeout @onConnectionEstablished, 1180
      # setTimeout @onAgentTypingStart, 2000
      # setTimeout @receiveMessage, 5000, "Hello! How can I help you?"
      @session_init()

    close: (event) =>
      event.stopPropagation() if event
      remainerHeight = @el.height() - @el.find('.zammad-chat-header').outerHeight()
      @el.animate { bottom: -remainerHeight }, 500, @onCloseAnimationEnd

    onCloseAnimationEnd: =>
      @el.removeClass('zammad-chat-is-open')
      @disconnect()
      @isOpen = false

      @send 'chat_session_close', {session_id: @session_id}

    hide: ->
      @el.removeClass('zammad-chat-is-visible')

    show: ->
      @el.addClass('zammad-chat-is-visible')

      remainerHeight = @el.outerHeight() - @el.find('.zammad-chat-header').outerHeight()

      @el.css 'bottom', -remainerHeight

    disableInput: ->
      @el.find('.zammad-chat-input').prop('disabled', true)
      @el.find('.zammad-chat-send').prop('disabled', true)

    enableInput: ->
      @el.find('.zammad-chat-input').prop('disabled', false)
      @el.find('.zammad-chat-send').prop('disabled', false)

    onQueue: (position) =>
      @log 'notice', 'onQueue', position
      @inQueue = true

      @el.find('.zammad-chat-body').html @view('waiting')
        position: position

    onAgentTypingStart: =>
      if @stopTypingId
        clearTimeout(@stopTypingId)
      @stopTypingId = setTimeout(@onAgentTypingEnd, 3000)

      # never display two typing indicators
      return if @el.find('.zammad-chat-message--typing').size()

      @maybeAddTimestamp()

      @el.find('.zammad-chat-body').append @view('typingIndicator')()

      @scrollToBottom()

    onAgentTypingEnd: =>
      @el.find('.zammad-chat-message--typing').remove()

    maybeAddTimestamp: ->
      timestamp = Date.now()

      if !@lastTimestamp or (timestamp - @lastTimestamp) > @showTimeEveryXMinutes * 60000
        label = @T('Today')
        time = new Date().toTimeString().substr 0,5
        if @lastAddedType is 'timestamp'
          # update last time
          @updateLastTimestamp label, time
          @lastTimestamp = timestamp
        else
          # add new timestamp
          @addStatus label, time
          @lastTimestamp = timestamp
          @lastAddedType = 'timestamp'

    updateLastTimestamp: (label, time) ->
      @el.find('.zammad-chat-body')
        .find('.zammad-chat-status')
        .last()
        .replaceWith @view('status')
          label: label
          time: time

    addStatus: (label, time) ->
      @el.find('.zammad-chat-body').append @view('status')
        label: label
        time: time

    scrollToBottom: ->
      @el.find('.zammad-chat-body').scrollTop($('.zammad-chat-body').prop('scrollHeight'))

    session_init: ->
      @send('chat_session_init')

    connect: =>
      @log 'notice', "Connecting to #{@host}"
      @ws = new window.WebSocket(@host)
      @ws.onopen = =>
        @log 'debug', 'ws connected'
        @send 'chat_status_customer'
        @setAgentOnlineState(true)

      @ws.onmessage = @onWebSocketMessage

      @ws.onclose = (e) =>
        @log 'debug', 'close websocket connection'
        @reconnect()
        @setAgentOnlineState(false)

      @ws.onerror = (e) =>
        @log 'debug', 'ws:onerror', e

    reconnect: =>
      # set status to connecting
      @log 'notice', 'reconnecting'
      @disableInput()
      @lastAddedType = 'status'
      @el.find('.zammad-chat-agent-status').attr('data-status', 'connecting').text @T('Reconnecting')
      @addStatus @T('Connection lost')

      if @reconnectDelayId
        clearTimeout(@reconnectDelayId)
      @reconnectDelayId = setTimeout(@connect, 5000)

    onConnectionReestablished: =>
      # set status back to online
      @lastAddedType = 'status'
      @el.find('.zammad-chat-agent-status').attr('data-status', 'online').text @T('Online')
      @addStatus @T('Connection re-established')

    onSessionClosed: (data) ->
      @addStatus @T('Chat closed by %s', data.realname)
      @disableInput()

    disconnect: ->
      @showLoader()
      @el.find('.zammad-chat-welcome').removeClass('zammad-chat-is-hidden')
      @el.find('.zammad-chat-agent').addClass('zammad-chat-is-hidden')
      @el.find('.zammad-chat-agent-status').addClass('zammad-chat-is-hidden')

    onConnectionEstablished: (agent) =>
      @inQueue = false
      @agent = agent

      @el.find('.zammad-chat-agent').html @view('agent')
        agent: agent

      @enableInput()

      @el.find('.zammad-chat-body').empty()
      @el.find('.zammad-chat-welcome').addClass('zammad-chat-is-hidden')
      @el.find('.zammad-chat-agent').removeClass('zammad-chat-is-hidden')
      @el.find('.zammad-chat-agent-status').removeClass('zammad-chat-is-hidden')
      @el.find('.zammad-chat-input').focus()

    showLoader: ->
      @el.find('.zammad-chat-body').html @view('loader')()

    setAgentOnlineState: (state) =>
      @isOnline = state
      @el
        .find('.zammad-chat-agent-status')
        .toggleClass('zammad-chat-is-online', state)
        .text if state then @T('Online') else @T('Offline')

  $(document).ready ->
    window.zammadChat = new ZammadChat()
