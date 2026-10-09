defmodule PhxMediaLibrary.FFmpegTest do
  # VideoProcessor.FFmpeg: its commands and parsing against stub ffprobe and
  # ffmpeg executables on PATH, and against the real ones where installed.
  use PhxMediaLibrary.DataCase, async: false

  import PhxMediaLibrary.Fixtures

  alias PhxMediaLibrary.{Media, VideoProcessor.FFmpeg}

  @moduletag :db

  @probe_json ~s({"format": {"duration": "75.400", "bit_rate": "1250000"},
    "streams": [
      {"codec_type": "video", "codec_name": "h264", "width": 1280, "height": 720, "r_frame_rate": "30000/1001"},
      {"codec_type": "audio", "codec_name": "aac"}
    ]})

  setup do
    dir = Path.join(System.tmp_dir!(), "phx_media_ffmpeg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf(dir)
    end)

    %{dir: dir, real_path: path}
  end

  # A stub executable: prints `stdout` (a file's content) and exits with `status`,
  # recording its arguments in `<name>.args`.
  defp stub(dir, name, stdout_file, status \\ 0) do
    script = Path.join(dir, name)

    File.write!(script, """
    #!/bin/sh
    echo "$@" > "#{script}.args"
    #{if stdout_file, do: ~s(/bin/cat "#{stdout_file}"), else: ""}
    exit #{status}
    """)

    File.chmod!(script, 0o755)
  end

  defp on_path(dir), do: System.put_env("PATH", dir)

  defp fixture(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    path
  end

  describe "available?/0" do
    test "needs both ffprobe and ffmpeg", %{dir: dir} do
      on_path(dir)
      refute FFmpeg.available?()

      stub(dir, "ffprobe", nil)
      refute FFmpeg.available?()

      stub(dir, "ffmpeg", nil)
      assert FFmpeg.available?()
    end
  end

  describe "extract_metadata/1" do
    test "reads duration, bit rate, size, codecs and frame rate", %{dir: dir} do
      stub(dir, "ffprobe", fixture(dir, "probe.json", @probe_json))
      on_path(dir)

      assert {:ok, meta} = FFmpeg.extract_metadata("/videos/clip.mp4")

      assert meta == %{
               "duration" => 75.4,
               "bit_rate" => 1_250_000,
               "width" => 1280,
               "height" => 720,
               "codec" => "h264",
               "fps" => 29.97,
               "audio_codec" => "aac"
             }

      assert File.read!(Path.join(dir, "ffprobe.args")) =~
               "-show_streams -show_format /videos/clip.mp4"
    end

    test "falls back to the stream's duration; skips what's missing", %{dir: dir} do
      json =
        ~s({"format": {}, "streams": [{"codec_type": "video", "duration": "3", "r_frame_rate": "0/0"}]})

      stub(dir, "ffprobe", fixture(dir, "probe.json", json))
      on_path(dir)

      assert {:ok, %{"duration" => 3.0} = meta} = FFmpeg.extract_metadata("clip.mp4")
      refute Map.has_key?(meta, "fps")
    end

    test "errors: output that isn't JSON, a failed run, no ffprobe", %{dir: dir} do
      stub(dir, "ffprobe", fixture(dir, "probe.txt", "not json"))
      on_path(dir)
      assert {:error, _} = FFmpeg.extract_metadata("clip.mp4")

      stub(dir, "ffprobe", fixture(dir, "err.txt", "boom"), 1)
      assert {:error, {:ffprobe_failed, 1, "boom"}} = FFmpeg.extract_metadata("clip.mp4")

      File.rm!(Path.join(dir, "ffprobe"))
      assert {:error, :ffmpeg_not_available} = FFmpeg.extract_metadata("clip.mp4")
    end
  end

  describe "extract_poster/2" do
    test "returns the frame at the offset", %{dir: dir} do
      stub(dir, "ffmpeg", fixture(dir, "frame.jpg", <<0xFF, 0xD8, 0xFF, "frame">>))
      on_path(dir)

      assert {:ok, <<0xFF, 0xD8, 0xFF, "frame">>} = FFmpeg.extract_poster("clip.mp4", 2.5)
      assert File.read!(Path.join(dir, "ffmpeg.args")) =~ "-ss 2.500 -i clip.mp4 -frames:v 1"
    end

    test "errors: an empty frame, a failed run, a negative offset clamped", %{dir: dir} do
      stub(dir, "ffmpeg", fixture(dir, "empty.jpg", ""))
      on_path(dir)
      assert {:error, :empty_poster_frame} = FFmpeg.extract_poster("clip.mp4", -4.0)
      assert File.read!(Path.join(dir, "ffmpeg.args")) =~ "-ss 0.000"

      stub(dir, "ffmpeg", nil, 1)
      assert {:error, {:ffmpeg_failed, 1}} = FFmpeg.extract_poster("clip.mp4")
    end
  end

  test "a video upload gets its metadata and a poster", %{dir: dir} do
    stub(dir, "ffprobe", fixture(dir, "probe.json", @probe_json))
    jpeg = create_temp_image(format: :jpg, width: 64, height: 36)
    on_exit(fn -> File.rm(jpeg) end)
    stub(dir, "ffmpeg", jpeg)
    on_path(dir)

    # An MP4 header, so the type is detected from the bytes.
    video =
      create_temp_file(
        <<0, 0, 0, 24, "ftypisom", 0, 0, 2, 0, "isomiso2">> <> :binary.copy("x", 64),
        "clip.mp4"
      )

    on_exit(fn -> File.rm(video) end)

    {:ok, media} =
      create_test_post()
      |> PhxMediaLibrary.add(video)
      |> PhxMediaLibrary.to_collection(:images, disk: :local)

    on_exit(fn -> Media.delete_files(media) end)

    assert media.mime_type == "video/mp4"
    assert media.metadata["duration"] == 75.4
    assert media.metadata["codec"] == "h264"
    assert %{"path" => poster} = media.responsive_images["poster"]
    assert File.exists?(Path.join("priv/static/uploads", poster))
  end

  describe "with the real binaries" do
    @describetag :ffmpeg

    test "metadata and a poster from a generated clip", %{dir: dir, real_path: path} do
      System.put_env("PATH", path)
      clip = Path.join(dir, "clip.mp4")

      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-v quiet -f lavfi -i testsrc=size=320x240:rate=25 -t 1 -pix_fmt yuv420p #{clip})
        )

      assert {:ok, %{"width" => 320, "height" => 240, "fps" => 25.0}} =
               FFmpeg.extract_metadata(clip)

      assert {:ok, <<0xFF, 0xD8, _::binary>>} = FFmpeg.extract_poster(clip, 0.5)
    end
  end
end
