const fs = require('fs');
const path = require('path');

// The admin-editable system prompt. Mounted read-only at /app/system-prompt.md
// (see docker-compose) and read per call, so edits take effect on the next call
// without rebuilding or restarting the container.
const PROMPT_PATH = process.env.SYSTEM_PROMPT_PATH || path.join(__dirname, '../../system-prompt.md');
const DEFAULT_PROMPT =
  'You are a friendly, helpful voice assistant on a phone call. ' +
  'Keep responses concise and natural for spoken conversation.';

const loadSystemPrompt = (logger) => {
  try {
    const txt = fs.readFileSync(PROMPT_PATH, 'utf8').trim();
    if (txt) return txt;
    logger.warn(`system prompt ${PROMPT_PATH} is empty, using default`);
  } catch (err) {
    logger.warn({err}, `could not read system prompt ${PROMPT_PATH}, using default`);
  }
  return DEFAULT_PROMPT;
};

const service = ({logger, makeService}) => {
  const svc = makeService({path: '/openai-s2s'});

  svc.on('session:new', (session, path) => {
    session.locals = { ...session.locals,
      logger: logger.child({call_sid: session.call_sid})
    };
    session.locals.logger.info({session, path}, `new incoming call: ${session.call_sid}`);

    session
      .on('/event', onEvent.bind(null, session))
      .on('/final', onFinal.bind(null, session))
      .on('close', onClose.bind(null, session))
      .on('error', onError.bind(null, session));

    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) {
      session.locals.logger.info('missing env OPENAI_API_KEY, hanging up');
      session.hangup().send();
      return;
    }

    const instructions = loadSystemPrompt(session.locals.logger);

    session
      .answer()
      .pause({length: 1})
      .llm({
        vendor: 'openai',
        model: 'gpt-realtime',
        auth: {apiKey},
        actionHook: '/final',
        eventHook: '/event',
        events: [
          'conversation.item.*',
          'response.output_audio_transcript.done',
          'input_audio_buffer.committed'
        ],
        llmOptions: {
          response_create: {
            output_modalities: ['audio'],
            instructions: 'Greet the caller warmly and briefly, then help according to your instructions.',
            audio: {
              output: {voice: 'alloy', format: {type: 'audio/pcm', rate: 24000}}
            },
            max_output_tokens: 4096
          },
          session_update: {
            type: 'realtime',
            // The voicebot's behaviour/persona — taken verbatim from system-prompt.md.
            instructions,
            audio: {
              input: {
                format: {type: 'audio/pcm', rate: 24000},
                transcription: {model: 'whisper-1'},
                turn_detection: {
                  type: 'server_vad',
                  threshold: 0.8,
                  prefix_padding_ms: 300,
                  silence_duration_ms: 500
                }
              },
              output: {
                format: {type: 'audio/pcm', rate: 24000},
                voice: 'alloy'
              }
            }
          }
        }
      })
      .hangup()
      .send();
  });
};

const onFinal = async(session, evt) => {
  const {logger} = session.locals;
  logger.info(`got actionHook: ${JSON.stringify(evt)}`);
  if (['server failure', 'server error'].includes(evt.completion_reason)) {
    session.say({text: 'Sorry, there was an error processing your request.'});
    session.hangup();
  }
  session.reply();
};

const onEvent = async(session, evt) => {
  const {logger} = session.locals;
  logger.info(`got eventHook: ${JSON.stringify(evt)}`);
};

const onClose = (session, code, reason) => {
  const {logger} = session.locals;
  logger.info({code, reason}, `session ${session.call_sid} closed`);
};

const onError = (session, err) => {
  const {logger} = session.locals;
  logger.info({err}, `session ${session.call_sid} received error`);
};

module.exports = service;
