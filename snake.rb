# Nokia-style Snake in Ruby with raylib-bindings

require 'raylib'

shared_lib_path = Gem::Specification.find_by_name('raylib-bindings').full_gem_path + '/lib/'

case RUBY_PLATFORM
when /mswin|msys|mingw|cygwin/
  Raylib.load_lib(shared_lib_path + 'libraylib.dll')
when /darwin/
  arch = RUBY_PLATFORM.split('-')[0]
  Raylib.load_lib(shared_lib_path + "libraylib.#{arch}.dylib")
when /linux/
  arch = RUBY_PLATFORM.split('-')[0]
  Raylib.load_lib(shared_lib_path + "libraylib.#{arch}.so")
else
  raise "Unknown OS: #{RUBY_PLATFORM}"
end

include Raylib

CELL          = 24
GRID_W        = 24
GRID_H        = 18
HUD_H         = 60
MARGIN        = 16
SCREEN_W      = GRID_W * CELL + MARGIN * 2
SCREEN_H      = GRID_H * CELL + HUD_H + MARGIN * 2
PLAY_X        = MARGIN
PLAY_Y        = MARGIN + HUD_H
TICK_START    = 0.14
TICK_MIN      = 0.05
TICK_STEP     = 0.004

LCD_BG        = Color.from_u8(170, 198, 120, 255)
LCD_DIM       = Color.from_u8(150, 178, 100, 255)
LCD_DARK      = Color.from_u8(30,  44,  20,  255)
LCD_FAINT     = Color.from_u8(30,  44,  20,  40)

FONT_PATH     = File.join(__dir__, 'nokiafc22.ttf')

module FontHolder
  class << self
    attr_accessor :font
  end
end

def draw_text_nokia(text, x, y, size, color)
  Raylib.DrawTextEx(FontHolder.font, text, Vector2.create(x, y), size, 1, color)
end

def measure_text_nokia(text, size)
  Raylib.MeasureTextEx(FontHolder.font, text, size, 1).x.to_i
end

module Sfx
  class << self
    attr_accessor :eat, :die, :_buffers
  end
  self._buffers = []

  # Build a mono 16-bit PCM square-wave blip with linear amplitude decay.
  # `start_hz` and `end_hz` allow a frequency sweep over the duration.
  def self.make_blip(start_hz:, end_hz: nil, duration:, sample_rate: 22050, volume: 0.25)
    end_hz ||= start_hz
    n = (sample_rate * duration).to_i
    phase = 0.0
    samples = Array.new(n) do |i|
      progress = i.to_f / n
      f = start_hz + (end_hz - start_hz) * progress
      phase = (phase + f / sample_rate) % 1.0
      sq = phase < 0.5 ? 1.0 : -1.0
      env = 1.0 - progress
      (sq * env * volume * 32767).to_i.clamp(-32767, 32767)
    end

    buffer = FFI::MemoryPointer.new(:int16, n)
    buffer.write_array_of_int16(samples)
    _buffers << buffer  # retain so GC doesn't free it

    wave = Raylib::Wave.new
    wave[:frameCount] = n
    wave[:sampleRate] = sample_rate
    wave[:sampleSize] = 16
    wave[:channels]   = 1
    wave[:data]       = buffer

    Raylib.LoadSoundFromWave(wave)
  end

  def self.load_all
    self.eat = make_blip(start_hz: 880, duration: 0.07, volume: 0.25)
    self.die = make_blip(start_hz: 440, end_hz: 80, duration: 0.45, volume: 0.30)
  end

  def self.unload_all
    Raylib.UnloadSound(eat) if eat
    Raylib.UnloadSound(die) if die
  end
end

class SnakeGame
  attr_reader :score

  def initialize
    reset
  end

  def reset
    mid_x = GRID_W / 2
    mid_y = GRID_H / 2
    @snake = [[mid_x - 2, mid_y], [mid_x - 1, mid_y], [mid_x, mid_y]]
    @dir   = [1, 0]
    @next_dir = @dir
    @grow_pending = 0
    @score = 0
    @tick = TICK_START
    @accum = 0.0
    @state = :playing
    @flash = 0.0
    place_food
  end

  def state = @state

  def handle_input
    if IsKeyPressed(KEY_UP)    || IsKeyPressed(KEY_W); queue_dir(0, -1); end
    if IsKeyPressed(KEY_DOWN)  || IsKeyPressed(KEY_S); queue_dir(0,  1); end
    if IsKeyPressed(KEY_LEFT)  || IsKeyPressed(KEY_A); queue_dir(-1, 0); end
    if IsKeyPressed(KEY_RIGHT) || IsKeyPressed(KEY_D); queue_dir(1,  0); end

    if IsKeyPressed(KEY_SPACE)
      @state = :paused  if @state == :playing
      @state = :playing if @state == :paused
    end

    if IsKeyPressed(KEY_R) && @state == :gameover
      reset
    end
  end

  def update(dt)
    return unless @state == :playing
    @accum += dt
    while @accum >= @tick
      @accum -= @tick
      step
      break unless @state == :playing
    end
    @flash -= dt if @flash > 0
  end

  def draw
    draw_hud
    draw_play_area
    draw_food
    draw_snake
    draw_overlay
  end

  private

  def queue_dir(dx, dy)
    return if [dx, dy] == [-@dir[0], -@dir[1]] && @snake.size > 1
    @next_dir = [dx, dy]
  end

  def step
    @dir = @next_dir
    head = @snake.last
    nx = head[0] + @dir[0]
    ny = head[1] + @dir[1]

    if nx < 0 || nx >= GRID_W || ny < 0 || ny >= GRID_H
      die!
      return
    end

    will_eat = (nx == @food[0] && ny == @food[1])
    body_to_check = will_eat ? @snake : @snake[1..]
    if body_to_check.any? { |s| s[0] == nx && s[1] == ny }
      die!
      return
    end

    @snake.push([nx, ny])
    if will_eat
      @score += 1
      @flash = 0.12
      @tick = [@tick - TICK_STEP, TICK_MIN].max
      PlaySound(Sfx.eat) if Sfx.eat
      place_food
    else
      @snake.shift
    end
  end

  def die!
    @state = :gameover
    PlaySound(Sfx.die) if Sfx.die
  end

  def place_food
    occupied = @snake.to_set rescue @snake
    loop do
      pos = [rand(GRID_W), rand(GRID_H)]
      unless @snake.any? { |s| s[0] == pos[0] && s[1] == pos[1] }
        @food = pos
        return
      end
    end
  end

  def cell_rect(gx, gy, inset = 2)
    [PLAY_X + gx * CELL + inset, PLAY_Y + gy * CELL + inset, CELL - inset * 2, CELL - inset * 2]
  end

  def draw_hud
    ClearBackground(LCD_BG)
    title = "SNAKE"
    draw_text_nokia(title, MARGIN, MARGIN + 6, 28, LCD_DARK)
    score_text = "SCORE  %03d" % @score
    sw = measure_text_nokia(score_text, 24)
    draw_text_nokia(score_text, SCREEN_W - MARGIN - sw, MARGIN + 10, 24, LCD_DARK)

    len_text = "LEN  %02d" % @snake.size
    lw = measure_text_nokia(len_text, 16)
    draw_text_nokia(len_text, SCREEN_W - MARGIN - lw, MARGIN + 38, 16, LCD_DARK)
  end

  def draw_play_area
    DrawRectangleLinesEx(Rectangle.create(PLAY_X - 4, PLAY_Y - 4,
                                          GRID_W * CELL + 8, GRID_H * CELL + 8),
                         3, LCD_DARK)

    # faint dotted grid for that LCD pixel feel
    (0...GRID_W).each do |gx|
      (0...GRID_H).each do |gy|
        DrawRectangle(PLAY_X + gx * CELL + CELL / 2 - 1,
                      PLAY_Y + gy * CELL + CELL / 2 - 1,
                      2, 2, LCD_FAINT)
      end
    end
  end

  def draw_food
    x, y, w, h = cell_rect(@food[0], @food[1], 4)
    color = @flash > 0 ? LCD_DIM : LCD_DARK
    DrawRectangle(x, y, w, h, color)
    DrawRectangle(x + w / 4, y + h / 4, w / 2, h / 2, LCD_BG)
  end

  def draw_snake
    @snake.each_with_index do |(gx, gy), i|
      x, y, w, h = cell_rect(gx, gy, 2)
      DrawRectangle(x, y, w, h, LCD_DARK)
      # inner pixel highlight
      DrawRectangle(x + 3, y + 3, w - 6, h - 6, LCD_DIM) if i == @snake.size - 1
    end
  end

  def draw_overlay
    case @state
    when :paused
      draw_centered_box(["PAUSED", "press SPACE"])
    when :gameover
      draw_centered_box(["GAME OVER", "score #{@score}", "press R to retry"])
    end
  end

  def draw_centered_box(lines)
    pad = 18
    line_h = 26
    box_w = 260
    box_h = pad * 2 + line_h * lines.size
    bx = PLAY_X + (GRID_W * CELL - box_w) / 2
    by = PLAY_Y + (GRID_H * CELL - box_h) / 2
    DrawRectangle(bx, by, box_w, box_h, LCD_BG)
    DrawRectangleLinesEx(Rectangle.create(bx, by, box_w, box_h), 3, LCD_DARK)
    lines.each_with_index do |text, i|
      size = i == 0 ? 24 : 18
      tw = measure_text_nokia(text, size)
      draw_text_nokia(text, bx + (box_w - tw) / 2, by + pad + i * line_h, size, LCD_DARK)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  InitWindow(SCREEN_W, SCREEN_H, "Nokia Snake - raylib-bindings")
  InitAudioDevice()
  SetTargetFPS(60)
  srand

  FontHolder.font = LoadFontEx(FONT_PATH, 32, nil, 0)
  SetTextureFilter(FontHolder.font.texture, TEXTURE_FILTER_POINT)
  Sfx.load_all

  game = SnakeGame.new

  until WindowShouldClose()
    game.handle_input
    game.update(GetFrameTime())

    BeginDrawing()
      game.draw
    EndDrawing()
  end

  Sfx.unload_all
  UnloadFont(FontHolder.font)
  CloseAudioDevice()
  CloseWindow()
end
