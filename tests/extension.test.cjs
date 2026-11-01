const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../src/spotify-touchbar.js'), 'utf8');
async function run() {
  const calls = [], timers = [];
  let payload;
  const player = {
    data: {item: {uri: 'spotify:track:a', metadata: {title: 'Test', artist_name: 'Artiste'}}},
    isPlaying: () => true, getDuration: () => 100000, getProgress: () => 25000,
    getVolume: () => 0.5, togglePlay: () => calls.push('play'),
    setVolume: value => calls.push(['volume', value]), seek: value => calls.push(['seek', value])
  };
  const context = {
    Spicetify: {Player: player}, AbortController, console,
    setTimeout: (f, ms) => { timers.push([f, ms]); return timers.length; }, clearTimeout() {}, addEventListener() {},
    fetch: async (_, options) => {
      payload = JSON.parse(options.body);
      return {ok: true, json: async () => ({commands: [
        {action: 'play'}, {action: 'volume', value: 3},
        {action: 'seek', value: 0.5, uri: 'spotify:track:old'},
        {action: 'seek', value: 0.75, uri: 'spotify:track:a'},
        {action: 'seek', value: 1, uri: 'spotify:track:a'}
      ]})};
    }
  };
  vm.runInNewContext(source, context);
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.deepEqual(calls, ['play', ['volume', 1], ['seek', 75000], ['seek', 100000]]);
  assert.equal(payload.title, 'Test'); assert.equal(payload.position, 25000);
  assert.equal(timers.at(-1)[1], 500);
  vm.runInNewContext(source, context);
  assert.equal(calls.length, 4, 'a second injection must not start another client');
  // The legacy wrapper may report the end while Spotify is still buffering.
  let now = 100000;
  context.Date = {now: () => now};
  const state = {positionAsOfTimestamp: 20000, duration: 200000, timestamp: now,
    hasContext: true, isPaused: false, isBuffering: false, speed: 1};
  player.origin = {getState: () => state};
  context.fetch = async (_, options) => {
    payload = JSON.parse(options.body);
    return {ok: true, json: async () => ({commands: []})};
  };
  async function sample(expected, label) {
    await timers.at(-1)[0]();
    assert.equal(payload.position, expected, label);
    assert.equal(payload.duration, state.duration);
  }
  now += 1000; await sample(21000, 'one real second advances one second');
  now += 1000; await sample(22000, 'polling must not accumulate time twice');
  state.speed = 0.5; await sample(21000, 'respect playback speed');
  state.isBuffering = true; now += 180000;
  await sample(20000, 'buffering must not fill the timeline');
  state.isBuffering = false; state.isPaused = true;
  await sample(20000, 'pause stops the clock');
  state.isPaused = false; state.speed = 0;
  await sample(20000, 'zero playback speed stops the clock');
  state.speed = 1; state.timestamp = now; state.positionAsOfTimestamp = 5000;
  await sample(5000, 'seek updates the authoritative position');
  state.duration = 100000; state.positionAsOfTimestamp = 0;
  await sample(0, 'new track resets position and duration');
  now += 150000; await sample(100000, 'position is bounded by track duration');
  context.fetch = async () => { throw Error('offline'); };
  await timers.at(-1)[0]();
  assert.equal(timers.at(-1)[1], 750, 'connection failures use backoff');
  console.log('PASS: commands, state, volume clamp, stale seek, end seek, single instance, reconnect, playback clock, buffering, pause, speed, seek, track reset');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
