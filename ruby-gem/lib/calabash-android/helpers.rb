require "stringio"
require 'zip'
require 'tempfile'
require 'escape'
require 'rbconfig'
require 'calabash-android/java_keystore'

def package_name(app)
  package_line = aapt_dump(app, "package").first
  raise "'package' not found in aapt output" unless package_line
  m = package_line.match(/name='([^']+)'/)
  raise "Unexpected output from aapt: #{package_line}" unless m
  m[1]
end

def main_activity(app)
  begin
    log("Trying to find launchable activity")
    launchable_activity_line = aapt_dump(app, "launchable-activity").first
    raise "'launchable-activity' not found in aapt output" unless launchable_activity_line
    m = launchable_activity_line.match(/name='([^']+)'/)
    raise "Unexpected output from aapt: #{launchable_activity_line}" unless m
    log("Found launchable activity '#{m[1]}'")
    m[1]
  rescue => e
    log("Could not find launchable activity, trying to parse raw AndroidManifest. #{e.message}")

    manifest_data = `"#{Env.tools_dir}/aapt" dump xmltree "#{app}" AndroidManifest.xml`
    regex = /^\s*A:[\s*]android:name\(\w+\)\=\"android.intent.category.LAUNCHER\"/
    lines = manifest_data.lines.collect(&:strip)
    indicator_line = nil

    lines.each_with_index do |line, index|
      match = line.match(regex)

      unless match.nil?
        raise 'More than one launchable activity in AndroidManifest' unless indicator_line.nil?
        indicator_line = index
      end
    end

    raise 'No launchable activity found in AndroidManifest' unless indicator_line

    intent_filter_found = false

    (0..indicator_line).reverse_each do |index|
      if intent_filter_found
        match = lines[index].match(/\s*E:\s*activity-alias/)

        raise 'Could not find target activity in activity alias' if match

        match = lines[index].match(/^\s*A:\s*android:targetActivity\(\w*\)\=\"([^\"]+)/){$1}

        if match
          log("Found launchable activity '#{match}'")

          return match
        end
      else
        unless lines[index].match(/\s*E: intent-filter/).nil?
          log("Read intent filter")
          intent_filter_found = true
        end
      end
    end

    raise 'Could not find launchable activity'
  end
end

def aapt_dump(app, key)
  lines = `"#{Env.tools_dir}/aapt" dump badging "#{app}"`.lines.collect(&:strip)
  lines.select { |l| l.start_with?("#{key}:") }
end

def checksum(file_path)
  require 'digest/md5'
  Digest::MD5.file(file_path).hexdigest
end

def test_server_path(apk_file_path)
  "test_servers/#{checksum(apk_file_path)}_#{Calabash::Android::VERSION}.apk"
end

def build_test_server_if_needed(app_path)
  unless File.exist?(test_server_path(app_path))
    if ARGV.include? "--no-build"
      puts "No test server found for this combination of app and calabash version. Exiting!"
      exit 1
    else
      puts "No test server found for this combination of app and calabash version. Recreating test server."
      calabash_build(app_path)
    end
  end
end

def resign_apk(app_path)
  Dir.mktmpdir do |tmp_dir|
    log "Resign apk"
    unsigned_path = File.join(tmp_dir, 'unsigned.apk')
    unaligned_path = File.join(tmp_dir, 'unaligned.apk')
    FileUtils.cp(app_path, unsigned_path)
    unsign_apk(unsigned_path)
    sign_apk(unsigned_path, unaligned_path)
    zipalign_apk(unaligned_path, app_path)
  end
end

def unsign_apk(path)
  files_to_remove = `"#{Env.tools_dir}/aapt" list "#{path}"`.lines.collect(&:strip).grep(/^META-INF\//)
  if files_to_remove.empty?
    log "App wasn't signed. Will not try to unsign it."
  else
    system("\"#{Env.tools_dir}/aapt\" remove \"#{path}\" #{files_to_remove.join(" ")}")
  end
end

def zipalign_apk(inpath, outpath)
  system(%Q(#{Env.zipalign_path} -f 4 "#{inpath}" "#{outpath}"))
end

def sign_apk(app_path, dest_path)
  java_keystore = JavaKeystore.get_keystores.first
  java_keystore.sign_apk(app_path, dest_path)
end

def fingerprint_from_apk(app_path)
  app_path = File.expand_path(app_path)
  Dir.mktmpdir do |tmp_dir|
    Dir.chdir(tmp_dir) do
      FileUtils.cp(app_path, "app.apk")
      FileUtils.mkdir("META-INF")
      Zip::File.foreach("app.apk") do |z|
        z.extract if /^META-INF\/\w+.(RSA|rsa)/ =~ z.name
      end
      rsa_files = Dir["#{tmp_dir}/META-INF/*"]

      raise "No RSA file found in META-INF. Cannot proceed." if rsa_files.empty?
      raise "More than one RSA file found in META-INF. Cannot proceed." if rsa_files.length > 1

      cmd = "#{Env.keytool_path} -v -printcert -J\"-Dfile.encoding=utf-8\" -file \"#{rsa_files.first}\""
      log cmd
      fingerprints = `#{cmd}`
      md5_fingerprint = extract_md5_fingerprint(fingerprints)
      log "MD5 fingerprint for signing cert (#{app_path}): #{md5_fingerprint}"
      md5_fingerprint
    end
  end
end

def extract_md5_fingerprint(fingerprints)
  m = fingerprints.scan(/MD5.*((?:[a-fA-F\d]{2}:){15}[a-fA-F\d]{2})/).flatten
  raise "No MD5 fingerprint found:\n #{fingerprints}" if m.empty?
  m.first
end

def log(message, error = false)
  $stdout.puts "#{Time.now.strftime("%Y-%m-%d %H:%M:%S")} - #{message}" if (error or ARGV.include? "-v" or ARGV.include? "--verbose")
end
