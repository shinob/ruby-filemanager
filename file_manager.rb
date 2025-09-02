#!/usr/bin/env ruby
require 'socket'
require 'uri'
require 'cgi'
require 'fileutils'
require 'json'

class SimpleHTTPServer
  def initialize(root_dir, port = 8080)
    @root_dir = File.expand_path(root_dir)
    @port = port
  end

  def start
    server = TCPServer.new('0.0.0.0', @port)
    @threads = []
    
    puts "Starting file manager on port #{@port}"
    puts "Network access: http://[YOUR_IP]:#{@port}"
    puts "Local access: http://localhost:#{@port}"
    puts "Root directory: #{@root_dir}"
    puts "Press Ctrl+C to stop"

    Signal.trap('INT') do
      puts "\nShutting down..."
      server.close
      @threads.each { |t| t.kill if t.alive? }
      exit
    end

    loop do
      begin
        client = server.accept
        thread = Thread.new(client) { |c| handle_client(c) }
        @threads << thread
        @threads.reject! { |t| !t.alive? }
      rescue IOError
        break
      rescue => e
        puts "Error: #{e}" unless server.closed?
      end
    end
  end

  private

  def handle_client(client)
    request_line = client.gets
    return unless request_line

    method, path, version = request_line.split
    headers = {}
    content_length = 0
    client_ip = client.peeraddr[3] rescue 'unknown'

    while line = client.gets
      line.chomp!
      break if line.empty?
      key, value = line.split(': ', 2)
      headers[key.downcase] = value
      content_length = value.to_i if key.downcase == 'content-length'
    end

    body = content_length > 0 ? client.read(content_length) : ''

    # アクセスログ表示
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    user_agent = headers['user-agent'] || 'Unknown'
    puts "[#{timestamp}] #{client_ip} - #{method} #{path} - #{user_agent}"

    case method
    when 'GET'
      handle_get(client, path, headers)
    when 'POST'
      handle_post(client, path, body, headers['content-type'])
    else
      send_response(client, 405, 'Method Not Allowed', 'text/plain', 'Method Not Allowed')
    end

    client.close
  rescue => e
    puts "Error handling client: #{e}"
    client.close rescue nil
  end

  def handle_get(client, path, headers = {})
    uri = URI.parse(path)
    file_path = CGI.unescape(uri.path)
    query = CGI.parse(uri.query || '')
    
    # URLパスを正規化（常にスラッシュ区切り）
    file_path = file_path.gsub('\\', '/')
    file_path = '/' if file_path.empty?
    
    # セキュリティのため相対パス要素を除去
    path_parts = file_path.split('/').reject { |part| part.empty? || part == '.' || part == '..' }
    clean_path = '/' + path_parts.join('/')
    
    # ファイルシステム上の絶対パスを構築
    if clean_path == '/'
      full_path = @root_dir
    else
      relative_path = path_parts.join(File::SEPARATOR)
      full_path = File.join(@root_dir, relative_path)
    end

    unless full_path.start_with?(@root_dir)
      send_response(client, 403, 'Forbidden', 'text/plain', 'Access denied')
      return
    end

    if File.directory?(full_path)
      show_directory(client, clean_path, full_path)
    elsif File.file?(full_path)
      # ビューアーモードのチェック
      if query['view']&.first == 'text' && is_text_file?(full_path)
        show_text_file(client, full_path, clean_path, query['encoding']&.first)
      elsif query['view']&.first == 'video' && is_video_file?(full_path)
        show_video_file(client, full_path, clean_path)
      else
        serve_file(client, full_path, headers)
      end
    else
      send_response(client, 404, 'Not Found', 'text/plain', 'File not found')
    end
  end

  def handle_post(client, path, body, content_type)
    uri = URI.parse(path)
    query = CGI.parse(uri.query || '')
    action = query['action']&.first
    target_path = query['path']&.first

    unless target_path
      send_response(client, 400, 'Bad Request', 'text/plain', 'Missing path parameter')
      return
    end

    full_path = File.join(@root_dir, CGI.unescape(target_path))

    unless full_path.start_with?(@root_dir)
      send_response(client, 403, 'Forbidden', 'text/plain', 'Access denied')
      return
    end

    # POSTボディのパラメータも解析
    post_params = {}
    if body && !body.empty? && content_type && content_type.include?('application/x-www-form-urlencoded')
      post_params = CGI.parse(body)
    end
    
    # クエリパラメータとPOSTパラメータをマージ
    all_params = query.merge(post_params)

    case action
    when 'upload'
      handle_upload(client, full_path, body, content_type)
    when 'delete'
      handle_delete(client, full_path, target_path)
    when 'rename'
      handle_rename(client, all_params, target_path)
    else
      send_response(client, 400, 'Bad Request', 'text/plain', 'Unknown action')
    end
  end

  def show_directory(client, path, full_path)
    entries = []
    Dir.entries(full_path).sort.each do |entry|
      next if entry == '.' || entry == '..'
      
      entry_path = File.join(full_path, entry)
      is_dir = File.directory?(entry_path)
      size = is_dir ? '-' : File.size(entry_path)
      mtime = File.mtime(entry_path).strftime('%Y-%m-%d %H:%M:%S')
      
      # パスを正規化（Windowsの区切り文字対応）
      web_path = path == '/' ? "/#{entry}" : "#{path}/#{entry}"
      web_path = web_path.gsub(/\/+/, '/')  # 重複スラッシュを除去
      
      entries << {
        name: entry,
        is_directory: is_dir,
        size: size,
        mtime: mtime,
        path: web_path
      }
    end

    html = generate_html(path, entries)
    send_response(client, 200, 'OK', 'text/html; charset=UTF-8', html)
  end

  def serve_file(client, full_path, headers = {})
    content_type = guess_content_type(full_path)
    
    # すべてのファイルでRange requestをサポート（特に動画ファイル用）
    serve_with_range_support(client, full_path, content_type, headers)
  rescue => e
    send_response(client, 500, 'Internal Server Error', 'text/plain', "Error reading file: #{e}")
  end

  def handle_upload(client, dir_path, body, content_type)
    unless File.directory?(dir_path)
      send_response(client, 400, 'Bad Request', 'text/plain', 'Directory not found')
      return
    end

    if content_type&.include?('multipart/form-data')
      boundary = content_type[/boundary=(.+)$/, 1]
      if boundary
        parse_multipart_upload(body, boundary, dir_path)
      end
    end

    # アップロード後は同じディレクトリにリダイレクト
    if dir_path == @root_dir
      redirect_path = '/'
    else
      # ルートディレクトリからの相対パスを計算
      relative_path = dir_path.sub(@root_dir, '')
      relative_path = relative_path.gsub('\\', '/').sub(/^\//, '')
      redirect_path = relative_path.empty? ? '/' : "/#{relative_path}"
    end
    
    redirect_response(client, redirect_path)
  end

  def parse_multipart_upload(body, boundary, dir_path)
    parts = body.split("--#{boundary}")
    parts.each do |part|
      next unless part.include?('Content-Disposition: form-data')
      
      if match = part.match(/name="file".*?filename="(.+?)"/m)
        filename = match[1]
        content_start = part.index("\r\n\r\n")
        next unless content_start
        
        content = part[content_start + 4..-1]
        content = content.chomp("\r\n") if content.end_with?("\r\n")
        
        File.open(File.join(dir_path, filename), 'wb') do |file|
          file.write(content)
        end
        break
      end
    end
  end

  def handle_delete(client, target_path, original_path)
    unless File.exist?(target_path)
      send_response(client, 404, 'Not Found', 'text/plain', 'File not found')
      return
    end

    if File.directory?(target_path)
      FileUtils.rm_rf(target_path)
    else
      File.delete(target_path)
    end

    redirect_path = File.dirname(original_path)
    redirect_path = '/' if redirect_path == '.'
    redirect_response(client, redirect_path)
  end

  def handle_rename(client, query, target_path)
    old_name = query['old_name']&.first
    new_name = query['new_name']&.first
    
    unless old_name && new_name && !old_name.empty? && !new_name.empty?
      send_response(client, 400, 'Bad Request', 'text/plain', 'Invalid names')
      return
    end

    dir_path = File.dirname(File.join(@root_dir, CGI.unescape(target_path)))
    old_path = File.join(dir_path, CGI.unescape(old_name))
    new_path = File.join(dir_path, CGI.unescape(new_name))

    unless File.exist?(old_path)
      send_response(client, 404, 'Not Found', 'text/plain', 'File not found')
      return
    end

    File.rename(old_path, new_path)

    redirect_path = File.dirname(target_path)
    redirect_path = '/' if redirect_path == '.'
    redirect_response(client, redirect_path)
  end

  def generate_html(current_path, entries)
    current_path = '/' if current_path.empty?
    
    # 親ディレクトリのパスを計算
    parent_path = current_path == '/' ? nil : File.dirname(current_path)
    parent_path = '/' if parent_path == '.'
    
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>File Manager - #{current_path}</title>
        <style>
          body { font-family: Arial, sans-serif; margin: 20px; }
          table { border-collapse: collapse; width: 100%; }
          th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
          th { background-color: #f2f2f2; }
          .upload-form { margin: 20px 0; padding: 10px; background: #f9f9f9; }
          .actions { white-space: nowrap; }
          a { text-decoration: none; color: #0066cc; }
          a:hover { text-decoration: underline; }
          .rename-form { display: inline; }
          .rename-form input[type="text"] { width: 120px; }
          .parent-link { margin: 10px 0; }
          .image-file { color: #0066cc; cursor: pointer; text-decoration: none; }
          .image-file:hover { opacity: 0.8; text-decoration: underline; }
        </style>
        <script>
          function openImageModal(src, name) {
            const modal = document.getElementById('imageModal');
            const modalImg = document.getElementById('modalImage');
            const caption = document.getElementById('caption');
            modal.style.display = 'block';
            modalImg.src = src;
            caption.innerHTML = name;
          }
          
          function closeImageModal() {
            document.getElementById('imageModal').style.display = 'none';
          }
        </script>
      </head>
      <body>
        <h1>File Manager</h1>
        <p>Current directory: #{current_path}</p>
        #{parent_path ? "<div class=\"parent-link\"><a href=\"#{parent_path}\">← 親ディレクトリに戻る</a></div>" : ''}
        
        <div class="upload-form">
          <h3>Upload File</h3>
          <form method="POST" enctype="multipart/form-data" action="?action=upload&path=#{CGI.escape(current_path)}">
            <input type="file" name="file" required>
            <input type="submit" value="Upload">
          </form>
        </div>

        <div id="imageModal" style="display:none; position:fixed; z-index:1000; left:0; top:0; width:100%; height:100%; overflow:auto; background-color:rgba(0,0,0,0.9);">
          <span onclick="closeImageModal()" style="position:absolute; top:15px; right:35px; color:#f1f1f1; font-size:40px; font-weight:bold; cursor:pointer;">&times;</span>
          <img id="modalImage" style="margin:auto; display:block; width:80%; max-width:700px; margin-top:50px;">
          <div id="caption" style="margin:auto; display:block; width:80%; max-width:700px; text-align:center; color:#ccc; padding:10px 0;"></div>
        </div>

        <table>
          <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Size</th>
            <th>Modified</th>
            <th>Actions</th>
          </tr>
    HTML

    entries.each do |entry|
      type = entry[:is_directory] ? 'Directory' : 'File'
      
      # URLエンコード（日本語対応）
      encoded_path = entry[:path].split('/').map { |part| CGI.escape(part) }.join('/')
      
      if entry[:is_directory]
        name_cell = "<a href=\"#{encoded_path}\">📁 #{entry[:name]}/</a>"
      elsif is_image?(entry[:name])
        name_cell = "<span class=\"image-file\" onclick=\"openImageModal('#{encoded_path}', '#{entry[:name]}')\">　#{entry[:name]} 📷</span>"
      elsif is_video_file?(File.join(@root_dir, entry[:path].sub('/', '')))
        name_cell = "<a href=\"#{encoded_path}?view=video\">　#{entry[:name]} 🎬</a>"
      elsif is_text_file?(File.join(@root_dir, entry[:path].sub('/', '')))
        name_cell = "<a href=\"#{encoded_path}?view=text\">　#{entry[:name]} 📄</a>"
      else
        name_cell = "<a href=\"#{encoded_path}\">　#{entry[:name]}</a>"
      end
      
      delete_link = "?action=delete&path=#{CGI.escape(entry[:path])}"
      rename_action = "?action=rename&path=#{CGI.escape(entry[:path])}&old_name=#{CGI.escape(entry[:name])}"

      html << <<~ROW
        <tr>
          <td>#{name_cell}</td>
          <td>#{type}</td>
          <td>#{entry[:size]}</td>
          <td>#{entry[:mtime]}</td>
          <td class="actions">
            <form method="POST" style="display:inline;" action="#{delete_link}">
              <input type="submit" value="Delete" onclick="return confirm('Delete #{entry[:name]}?')">
            </form>
            <form method="POST" class="rename-form" action="#{rename_action}">
              <input type="text" name="new_name" value="#{entry[:name]}">
              <input type="submit" value="Rename">
            </form>
          </td>
        </tr>
      ROW
    end

    html << <<~HTML
        </table>
      </body>
      </html>
    HTML

    html
  end

  def send_response(client, status, status_text, content_type, body)
    response = "HTTP/1.1 #{status} #{status_text}\r\n"
    response << "Content-Type: #{content_type}\r\n"
    response << "Content-Length: #{body.bytesize}\r\n"
    response << "Connection: close\r\n"
    response << "\r\n"
    response << body
    
    client.write(response)
  end

  def redirect_response(client, location)
    response = "HTTP/1.1 302 Found\r\n"
    response << "Location: #{location}\r\n"
    response << "Content-Length: 0\r\n"
    response << "Connection: close\r\n"
    response << "\r\n"
    
    client.write(response)
  end

  def guess_content_type(path)
    case File.extname(path).downcase
    when '.html', '.htm' then 'text/html'
    when '.css' then 'text/css'
    when '.js' then 'application/javascript'
    when '.json' then 'application/json'
    when '.png' then 'image/png'
    when '.jpg', '.jpeg' then 'image/jpeg'
    when '.gif' then 'image/gif'
    when '.txt' then 'text/plain'
    when '.pdf' then 'application/pdf'
    when '.mp4', '.m4v' then 'video/mp4'
    when '.webm' then 'video/webm'
    when '.ogg' then 'video/ogg'
    when '.avi' then 'video/x-msvideo'
    when '.mov' then 'video/quicktime'
    when '.wmv' then 'video/x-ms-wmv'
    when '.flv' then 'video/x-flv'
    when '.mkv' then 'video/x-matroska'
    else 'application/octet-stream'
    end
  end

  def is_image?(filename)
    ['.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp'].include?(File.extname(filename).downcase)
  end

  def is_video_file?(filepath)
    video_extensions = ['.mp4', '.webm', '.ogg', '.avi', '.mov', '.wmv', '.flv', '.mkv', '.m4v']
    video_extensions.include?(File.extname(filepath).downcase)
  end

  def is_text_file?(filepath)
    text_extensions = ['.txt', '.log', '.md', '.rb', '.py', '.js', '.html', '.htm', '.css', '.json', '.xml', '.yml', '.yaml', '.csv', '.ini', '.cfg', '.conf', '.sh', '.bat', '.cmd']
    ext = File.extname(filepath).downcase
    return true if text_extensions.include?(ext)
    
    # 拡張子がない場合やその他の場合、ファイル内容をサンプリングしてテキストファイルか判定
    return false unless File.file?(filepath)
    begin
      sample = File.open(filepath, 'rb') { |f| f.read(512) }
      return false if sample.empty?
      # バイナリファイルの検出（NULL文字や制御文字の存在をチェック）
      sample.bytes.count { |b| b == 0 || (b < 32 && ![9, 10, 13].include?(b)) } < sample.size * 0.1
    rescue
      false
    end
  end

  def show_text_file(client, file_path, web_path, encoding = nil)
    encoding ||= 'UTF-8'
    
    begin
      content = File.read(file_path, encoding: "#{encoding}:UTF-8")
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      # エンコーディングエラーの場合、バイナリで読み込んで強制変換
      content = File.read(file_path, encoding: 'BINARY')
      content = content.encode('UTF-8', encoding, invalid: :replace, undef: :replace, replace: '?')
    rescue => e
      content = "Error reading file: #{e.message}"
    end
    
    html = generate_text_viewer_html(web_path, content, encoding)
    send_response(client, 200, 'OK', 'text/html; charset=UTF-8', html)
  end

  def generate_text_viewer_html(file_path, content, current_encoding)
    encodings = ['UTF-8', 'Shift_JIS', 'EUC-JP', 'ISO-2022-JP', 'Windows-31J', 'ASCII-8BIT']
    file_name = File.basename(file_path)
    parent_dir = File.dirname(file_path)
    parent_dir = '/' if parent_dir == '.'
    parent_url = parent_dir.split('/').map { |part| CGI.escape(part) }.join('/')
    
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>Text Viewer - #{CGI.escapeHTML(file_name)}</title>
        <style>
          body { font-family: monospace; margin: 20px; background: #f5f5f5; }
          .header { background: white; padding: 15px; border-radius: 5px; margin-bottom: 10px; }
          .content { background: white; padding: 20px; border-radius: 5px; white-space: pre-wrap; word-wrap: break-word; }
          .encoding-selector { margin: 10px 0; }
          select { padding: 5px; }
          .back-button { text-decoration: none; color: #0066cc; }
          .back-button:hover { text-decoration: underline; }
        </style>
      </head>
      <body>
        <div class="header">
          <h2>📄 #{CGI.escapeHTML(file_name)}</h2>
          <a href="#{parent_url}" class="back-button">← ディレクトリに戻る</a>
          
          <div class="encoding-selector">
            <label for="encoding">エンコーディング: </label>
            <select id="encoding" onchange="changeEncoding()">
    HTML
    
    encodings.each do |enc|
      selected = enc == current_encoding ? ' selected' : ''
      html << "              <option value=\"#{enc}\"#{selected}>#{enc}</option>\n"
    end
    
    html << <<~HTML
            </select>
          </div>
        </div>
        
        <div class="content">#{CGI.escapeHTML(content)}</div>
        
        <script>
          function changeEncoding() {
            const encoding = document.getElementById('encoding').value;
            const url = new URL(window.location);
            url.searchParams.set('encoding', encoding);
            window.location.href = url.toString();
          }
        </script>
      </body>
      </html>
    HTML
    
    html
  end

  def show_video_file(client, file_path, web_path)
    html = generate_video_viewer_html(web_path, file_path)
    send_response(client, 200, 'OK', 'text/html; charset=UTF-8', html)
  end

  def generate_video_viewer_html(web_path, file_path)
    file_name = File.basename(web_path)
    parent_dir = File.dirname(web_path)
    parent_dir = '/' if parent_dir == '.'
    
    # 動画ファイルの直接URLを生成（適切にエンコード）
    video_url = web_path.split('/').map { |part| CGI.escape(part) }.join('/')
    # 親ディレクトリのURLも適切にエンコード
    parent_url = parent_dir.split('/').map { |part| CGI.escape(part) }.join('/')
    
    html = <<~HTML
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="UTF-8">
        <title>Video Viewer - #{file_name}</title>
        <style>
          body { 
            font-family: Arial, sans-serif; 
            margin: 0; 
            padding: 20px; 
            background: #000; 
            color: white;
            text-align: center;
          }
          .header { 
            background: rgba(255,255,255,0.1); 
            padding: 15px; 
            border-radius: 5px; 
            margin-bottom: 20px; 
            backdrop-filter: blur(10px);
          }
          .video-container {
            max-width: 100%;
            margin: 0 auto;
          }
          video {
            max-width: 100%;
            max-height: 80vh;
            border-radius: 8px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.5);
          }
          .back-button { 
            text-decoration: none; 
            color: #4CAF50; 
            font-weight: bold;
          }
          .back-button:hover { 
            text-decoration: underline; 
          }
          .download-button {
            display: inline-block;
            margin-top: 20px;
            padding: 10px 20px;
            background: #2196F3;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            font-weight: bold;
          }
          .download-button:hover {
            background: #1976D2;
            text-decoration: none;
          }
          .info {
            margin-top: 20px;
            color: #ccc;
            font-size: 14px;
          }
        </style>
      </head>
      <body>
        <div class="header">
          <h2>🎬 #{CGI.escapeHTML(file_name)}</h2>
          <a href="#{parent_url}" class="back-button">← ディレクトリに戻る</a>
        </div>
        
        <div class="video-container">
          <video controls preload="metadata">
            <source src="#{video_url}" type="#{get_video_mime_type(file_path)}">
            <p>お使いのブラウザは動画の再生に対応していません。</p>
          </video>
        </div>
        
        <div class="info">
          <a href="#{video_url}" download="#{CGI.escapeHTML(file_name)}" class="download-button">📥 ダウンロード</a>
          <p>動画が再生されない場合は、ダウンロードしてください。</p>
        </div>
        
        <script>
          // 動画の読み込み状態を監視
          const video = document.querySelector('video');
          video.addEventListener('error', function(e) {
            console.error('Video error:', e);
            document.querySelector('.info p').innerHTML = 
              '動画の読み込みに失敗しました。ファイル形式がブラウザでサポートされていない可能性があります。';
          });
          
          video.addEventListener('loadedmetadata', function() {
            console.log('Video loaded successfully');
          });
        </script>
      </body>
      </html>
    HTML
    
    html
  end

  def get_video_mime_type(file_path)
    case File.extname(file_path).downcase
    when '.mp4', '.m4v' then 'video/mp4'
    when '.webm' then 'video/webm'
    when '.ogg' then 'video/ogg'
    when '.avi' then 'video/x-msvideo'
    when '.mov' then 'video/quicktime'
    when '.wmv' then 'video/x-ms-wmv'
    when '.flv' then 'video/x-flv'
    when '.mkv' then 'video/x-matroska'
    else 'video/mp4'
    end
  end

  def serve_with_range_support(client, file_path, content_type, headers)
    file_size = File.size(file_path)
    range_header = headers['range']
    
    # 動画ファイルの場合は常にAccept-Rangesヘッダを追加
    supports_range = is_video_file?(file_path)
    
    if range_header && supports_range
      # Range request の処理
      if match = range_header.match(/bytes=(\d*)?-(\d*)?/)
        start_pos = match[1].to_s.empty? ? 0 : match[1].to_i
        end_pos = match[2].to_s.empty? ? file_size - 1 : match[2].to_i
        
        # 範囲を正規化
        start_pos = [start_pos, 0].max
        end_pos = [end_pos, file_size - 1].min
        content_length = end_pos - start_pos + 1
        
        # 206 Partial Content レスポンス
        response = "HTTP/1.1 206 Partial Content\r\n"
        response << "Content-Type: #{content_type}\r\n"
        response << "Content-Length: #{content_length}\r\n"
        response << "Content-Range: bytes #{start_pos}-#{end_pos}/#{file_size}\r\n"
        response << "Accept-Ranges: bytes\r\n"
        response << "Cache-Control: no-cache\r\n"
        response << "Connection: close\r\n"
        response << "\r\n"
        
        client.write(response)
        
        # チャンク単位でデータを送信
        File.open(file_path, 'rb') do |file|
          file.seek(start_pos)
          remaining = content_length
          while remaining > 0 && !client.closed?
            chunk_size = [remaining, 8192].min
            chunk = file.read(chunk_size)
            break unless chunk
            client.write(chunk)
            remaining -= chunk.size
          end
        end
      else
        # 不正なRange header - 通常のレスポンスを返す
        serve_full_file(client, file_path, content_type, file_size, supports_range)
      end
    else
      # 通常のリクエスト
      serve_full_file(client, file_path, content_type, file_size, supports_range)
    end
  rescue => e
    puts "Error serving file: #{e}"
    send_response(client, 500, 'Internal Server Error', 'text/plain', "Error serving file: #{e}")
  end

  def serve_full_file(client, file_path, content_type, file_size, supports_range = false)
    response = "HTTP/1.1 200 OK\r\n"
    response << "Content-Type: #{content_type}\r\n"
    response << "Content-Length: #{file_size}\r\n"
    response << "Accept-Ranges: bytes\r\n" if supports_range
    response << "Cache-Control: public, max-age=3600\r\n" unless supports_range
    response << "Connection: close\r\n"
    response << "\r\n"
    
    client.write(response)
    
    # チャンク単位でファイルを送信
    File.open(file_path, 'rb') do |file|
      while chunk = file.read(8192)
        break if client.closed?
        client.write(chunk)
      end
    end
  end
end

if __FILE__ == $0
  root_directory = ARGV[0] || '.'
  port = (ARGV[1] || 8080).to_i

  server = SimpleHTTPServer.new(root_directory, port)
  server.start
end
