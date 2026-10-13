# TRMNL Serverless transform for the Golden Globe Race 2026 tracker.
#
# Runs on TRMNL's side after each poll. Fetches the YB Tracking race setup,
# leaderboard and the binary position feed, decodes the positions, and returns
# a compact set of merge variables for the Liquid templates.
#
# TRMNL pastes this file into a wrapper script and calls run(input), so keep
# the top level free of side effects. Standard library only, on purpose.
# To try it locally: bin/run-transform
require 'json'
require 'net/http'
require 'uri'
require 'time'

RACE = 'ggr2026'
BASE = 'https://yb.tl'
NM = 1852.0 # metres per nautical mile
TIMEOUT = 3.5 # seconds per request; TRMNL kills the function after 5 in total
HEADERS = { 'User-Agent' => 'Mozilla/5.0 (compatible; trmnl-ggr/1.0)', 'Accept' => '*/*' }.freeze

# Port of YB's PositionParser.parse (AllPositions3 format).
# Returns { team_id => newest moment } where a moment has :lat, :lon, :at (unix), :dtf (m).
def decode_positions(buf)
  flags = buf.getbyte(0)
  has_alt = flags & 1 != 0
  has_dtf = flags & 2 != 0
  has_lap = flags & 4 != 0
  has_pc  = flags & 8 != 0
  ref = buf.byteslice(1, 4).unpack1('N')
  p = 5
  latest = {}
  while p < buf.bytesize
    tid, n = buf.byteslice(p, 4).unpack('nn')
    p += 4
    prev = nil
    n.times do |i|
      m = {}
      if buf.getbyte(p) & 0x80 != 0
        w = buf.byteslice(p, 2).unpack1('n')
        p += 2
        dlat, dlon = buf.byteslice(p, 4).unpack('s>s>')
        p += 4
        p += 2 if has_alt
        if has_dtf
          m[:dtf] = prev[:dtf] + buf.byteslice(p, 2).unpack1('s>')
          p += 2
          p += 1 if has_lap
        end
        p += 2 if has_pc
        m[:lat] = prev[:lat] + dlat
        m[:lon] = prev[:lon] + dlon
        m[:at] = prev[:at] - (w & 0x7FFF)
      else
        t, lat, lon = buf.byteslice(p, 12).unpack('Nl>l>')
        p += 12
        p += 2 if has_alt
        if has_dtf
          m[:dtf] = buf.byteslice(p, 4).unpack1('l>')
          p += 4
          p += 1 if has_lap
        end
        p += 4 if has_pc
        m[:lat] = lat
        m[:lon] = lon
        m[:at] = ref + t
      end
      latest[tid] = m if i.zero? # moments are newest-first
      prev = m
    end
  end
  latest.each_value do |m|
    m[:lat] /= 1e5
    m[:lon] /= 1e5
  end
  latest
end

# 'Damien Guillou' -> 'D. Guillou'; long compound names collapse to initials + last name.
def short_name(full, limit = 16)
  parts = full.split
  return full if parts.size < 2

  short = "#{parts[0][0]}. #{parts[1..].join(' ')}"
  short = "#{parts[0..-2].map { |w| "#{w[0]}." }.join(' ')} #{parts[-1]}" if short.size > limit && parts.size > 2
  short
end

# Decimated course as [lon, lat] runs, split where it crosses the antimeridian.
def course_segments(nodes, step = 12)
  pts = nodes.map { |n| [n['lon'].round(1), n['lat'].round(1)] }
  pts = pts.each_slice(step).map(&:first) + [pts.last].compact
  segments = []
  current = []
  pts.each do |pt|
    if current.any? && (pt[0] - current.last[0]).abs > 180
      segments << current
      current = []
    end
    current << pt
  end
  segments << current if current.any?
  segments
end

# Calendar day of the race in UTC, the start day being day 1.
def race_day(start, now)
  return nil unless start

  (Time.at(now).utc.to_date - Time.at(start).utc.to_date).to_i + 1
end

def fetch(path)
  uri = URI("#{BASE}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.open_timeout = TIMEOUT
  http.read_timeout = TIMEOUT
  res = http.get(uri.request_uri, HEADERS)
  raise "#{path}: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

  res.body
end

def build
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  threads = {
    setup: Thread.new { fetch("/JSON/#{RACE}/RaceSetup") },
    board: Thread.new { fetch("/JSON/#{RACE}/leaderboard") },
    positions: Thread.new { fetch("/BIN/#{RACE}/AllPositions3") }
  }
  threads.each_value { |t| t.report_on_exception = false } # #value re-raises in the caller
  setup = JSON.parse(threads[:setup].value)
  board = JSON.parse(threads[:board].value)
  raw_positions = threads[:positions].value.b
  raise 'YB tracker returned no race setup' unless setup.is_a?(Hash) && setup['teams'].is_a?(Array)
  raise 'YB tracker returned no leaderboard' unless board.is_a?(Hash) && board['tags'].is_a?(Array)
  raise 'YB tracker returned no positions' if raw_positions.bytesize < 5

  positions = decode_positions(raw_positions)

  tags = (setup['tags'] || []).to_h { |t| [t['id'], t] }
  ranks = {}
  (board['tags'] || []).each do |tag|
    tag['teams'].each { |row| ranks[row['id']] ||= row }
  end

  race_start = nil
  newest = 0
  boats = []
  setup['teams'].each do |team|
    tag_name = tags.dig(team['tags']&.first, 'name') || ''
    next if tag_name == 'Previous Competitors' # historical ghost tracks, not racing this year

    row = ranks[team['id']] || {}
    pos = positions[team['id']]
    race_start ||= team['start']
    dtf_m = row['dtf'] || pos&.dig(:dtf)
    newest = [newest, pos[:at]].max if pos
    boats << {
      'short' => short_name(team['name']),
      'boat' => team['owner'] || '',
      'status' => team['status'] || row['status'] || '',
      'chichester' => tag_name == 'Chichester Class',
      'rank' => row['rankR'],
      'dtf_nm' => dtf_m && (dtf_m / NM).round,
      'd24_nm' => row['d24'] && [0, (row['d24'] / NM).round].max,
      'lat' => pos && pos[:lat].round(2),
      'lon' => pos && pos[:lon].round(2)
    }
  end

  # Overall order: racing boats by rank, then Chichester, then retired.
  boats.sort_by! do |b|
    group = if b['status'] == 'RACING' && !b['chichester'] then 0
            elsif b['chichester'] then 1
            else 2
            end
    [group, b['rank'] || 999, b['dtf_nm'] || 10**9]
  end
  boats.each_with_index do |b, i|
    b['pos'] = i + 1
    b.delete('rank')
  end

  now = Time.now.to_i
  {
    'race' => {
      'title' => setup['title'] || 'Golden Globe Race',
      'day' => race_day(race_start, now),
      'updated' => newest.zero? ? now : newest,
      'racing' => boats.count { |b| b['status'] == 'RACING' },
      'total' => boats.size
    },
    'boats' => boats,
    'course' => course_segments(setup.dig('course', 'nodes') || []),
    'meta' => {
      'ruby' => RUBY_VERSION,
      'ms' => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    }
  }
end

def run(_input)
  build
rescue StandardError => e # surface the failure on the screen instead of a blank render
  { 'error' => "#{e.class}: #{e.message}"[0, 300] }
end
