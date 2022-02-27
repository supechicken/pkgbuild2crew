#!/usr/bin/env ruby
# convert.rb: convert PKGBUILD file into Chromebrew style recipe
#
# Usage:
#   convert.rb <PKGBUILD file>

def extract_cmdargs(cmd, max_params = -1)
  @in_round_bracket = @backsplash = @in_single_quotes = @in_double_quotes = false

  cmd.chars.map! do |char|
    # check if #{char} has a special meaning
    unless @backsplash
      case char
      when '"'
        # if a double quote char not being escaped/quoted by single quotes,
        # then treat it as a special char
        @in_double_quotes = !@in_double_quotes unless @in_single_quotes
      when "'"
        # if a single quote char not being escaped/quoted by double quotes,
        # then treat it as a special char
        @in_single_quotes = !@in_single_quotes unless @in_double_quotes
      when '\\'
        # if a backsplash char not being escaped/quoted by single quotes,
        # then treat it as a special char
        unless @in_single_quotes
          @backsplash = true
          next char # early return, prevent status being reset
        end
      when ' '
        # if a space char not being escaped/quoted, then it is a separator between params
        next '<separator>' unless @in_double_quotes or @in_single_quotes or @in_round_bracket
      when '(', ')'
        # if a round bracket char not being escaped/quoted,
        # then treat it as a special char
        @in_round_bracket = !@in_round_bracket unless @in_double_quotes or @in_single_quotes
      end
    end

    @backsplash = false # reset backsplash status backtick
    next char # return #{char} if it doesn't have a special meaning
  end.join('').split('<separator>', max_params)
end

def parse_bash_array(v)
  return v.scan(/\[\d\]=(?!\\)"(.*?)(?<!\\)"/).flatten
end

def keyword_convert(k, v)
  # convert special variables into corresponding function names in package.rb
  # remove starting/ending quote (if any)
  v = v[/^["'](.*)["']$/, 1] if v =~ /^['"].*['"]$/

  case k
  when 'pkgname'
    @pkgName = v
    @converted_buf.sub!('<pkgName>', v.capitalize)
  when 'pkgver'
    @converted_buf += "version #{v.inspect}\n"
  when 'arch'
    @converted_buf += "compatibility #{parse_bash_array(v).join(', ').inspect}\n"
  when 'url'
    @converted_buf += "homepage #{v.inspect}\n"
  when 'license'
    @converted_buf += "license #{parse_bash_array(v).join(', ').inspect}\n"
  when 'pkgdesc'
    @converted_buf += "description #{v.inspect}\n"
  when 'depends'
    parse_bash_array(v).each do |dep|
      dep.sub(/^[\<\>\=]*/, '').chomp # delete operators

      @converted_buf += "depends_on #{dep.inspect}\n"
    end
  when 'source'
    # since crew doesn't support multi sources, use first source only
    @source_url = parse_bash_array(v)[0]
    @converted_buf += "source_url #{@source_url.inspect}\n"
  when /.*sums$/
    # if sha256sums was given, use it
    # otherwise generate from source
    if k == 'sha256sums'
      sha256sums = parse_bash_array(v)[0]
    else
      puts "\e[1;33m""Generating sha256sum...""\e[0m"
      sha256sums = `curl -L# #{@source_url.inspect} | sha256sums`.split(/\s+/, 2)[0]
    end

    @converted_buf += "source_sha256 #{sha256sums.inspect}\n"
  end
end

def declare_cmd(cmdline)
  k = cmdline.split('=', 2)[0] # extract variable name

  # convert variable expression to `declare` style
  # comparing to Kernel.`, IO.popen doesn't need escaping
  # escape variables
  _, declare_opt, expression = extract_cmdargs(IO.popen(['bash', '-c', "#{cmdline.gsub(/([\$\`])/, '\\\\\1')}\ndeclare -p #{k}"]).read.chomp, 3)

  v = expression.split('=', 2)[-1].gsub("\\$", '$') # extract variable value parsed by bash

  return keyword_convert(k, v) if SpecialVar.include?(k)

  case declare_opt
  when /i/ # when -i option is specified, treat the value as int
    @converted_buf += "@_#{k} = #{v.to_i}\n"
  when /a/ # when -a option is specified, parse the value as array
    parsedArray = parse_bash_array(v) # parse bash style array
    @converted_buf += "@_#{k} = #{parsedArray.inspect}\n"
  else
    @converted_buf += "@_#{k} = #{v.inspect}\n"
  end

  if declare_opt =~ /x/ # if -x option is specified, export the variable to env
    @converted_buf += "ENV[#{k.inspect}] = @_#{k}\n"
  end
end

SpecialVar = %W[
  pkgbase
  pkgname
  pkgver
  pkgrel
  epoch
  pkgdesc
  arch
  url
  license
  groups
  depends
  makedepends
  checkdepends
  optdepends
  provides
  conflicts
  replaces
  backup
  options
  install
  changelog
  source
  noextract
  validpgpkeys
  md5sums
  sha1sums
  sha256sums
  sha224sums
  sha384sums
  sha512sums
  b2sums
]


@converted_buf = "require 'package'\n\nclass <pkgName> < Package\n"
@cmd_buf = '' # for multi-line command

File.foreach(ARGV[0], chomp: true) do |cmd|
  cmd.strip!

  # combine current line with pervious line if the pervious line does not met end (unresolved quotes/backsplash)
  unless @cmd_buf.empty?
    cmd = @cmd_buf + cmd
    @cmd_buf = ''
  end

  args = extract_cmdargs(cmd)

  # variables generated during extract_cmdargs, can check if the given command ended or not
  # (if not, read the rest of the command in next line)
  cmd_end = !(@in_round_bracket or @backsplash or @in_single_quotes or @in_double_quotes)

  if cmd_end
    case args[0].to_s.lines[0]
    when /^#/, nil
      # if #{cmd} is a comment, copy it
      @converted_buf += "#{cmd.to_s}\n"
    when 'local', 'declare', 'export', /^[^\s]+=/
      # pass #{cmd} to declare_cmd if it contains variable keywords
      declare_cmd(cmd)
    # rubyize commands
    when 'cd'
      dir = args[1]
      @converted_buf += "Dir.chdir(#{dir.inspect})\n"
    when 'rm', 'mkdir'
      # remove opt args and convert it to fileutils style
      targets = args[1..-1].reject {|a| a =~ /^-/ }
    
      case args[0]
      when 'rm'
        fileutils_action = 'rm_rf'
      when 'mkdir'
        fileutils_action = 'mkdir_p'
      end

      if targets.size == 1
        if targets[0] =~ /\*/ # use Dir.glob if globbing pattern is used
          @converted_buf += "FileUtils.#{fileutils_action} Dir[#{targets[0].inspect}]\n"
        else
          @converted_buf += "FileUtils.#{fileutils_action} #{targets[0].inspect}\n"
        end
      else
        # if two or more targets is given, add them to array
        if targets.any? {|arg| arg =~ /\*/ } # use Dir.glob if globbing pattern is used
          @converted_buf += "FileUtils.#{fileutils_action} Dir.glob(#{targets.inspect})\n"
        else
          @converted_buf += "FileUtils.#{fileutils_action} #{targets.inspect}\n"
        end
      end
    #####
    # convert to crew namespace
    when 'prepare()' # prepare => self.patch
      @converted_buf += "def self.patch\n"
    when 'pkgver()'  #  pkgver => not used by crew
      @converted_buf += "def self.__arch_pkgver__\n"
    when 'build()'   #   build => self.build
      @converted_buf += "def self.build\n"
    when 'check()'   #   check => self.check
      @converted_buf += "def self.check\n"
    when 'package()' # package => self.install
      @converted_buf += "def self.install\n"
    #####
    when '}' # end of function
      @converted_buf += "end\n"
    else # parse as normal command
      @converted_buf += "system #{cmd.inspect.gsub("\\n", "\n")}\n" # keep newlines
    end
  else
    # put the command to @cmdbuf, process together with next line
    @cmd_buf = "#{cmd}\n"
  end
end

SpecialVar2Crew = {
  'pkgname' => @pkgName,
   'pkgver' => "\#{version}",
   'pkgrel' => "\#{version[/.*\\-(.*)$/, 1]}", # use regex to find out the release number
   'srcdir' => "\#{Dir[\"\#{CREW_BREW_DIR}/\#{File.basename(__FILE__, '.rb')}.*.dir\"]}", # use Dir.glob to find out the source dir
   'pkgdir' => "\#{CREW_DEST_DIR}"
}

puts "\e[1;32m""Replacing variable substitution syntax...""\e[0m"
SpecialVar2Crew.each_pair do |k, v|
  # convert PKGBUILD's special variable substitution to crew's one (see SpecialVar2Crew for more info)
  @converted_buf.gsub!(/\${?#{k}}?/, v)
end
@converted_buf.gsub!(/\${?([^\w]*?)}?/, '#{@_\1}')

@converted_buf += "end\n" # close class

File.write('converted.rb', @converted_buf)
puts "\e[1;32m""Completed!""\e[0m"
puts "\e[1;36m""let rubocop do the rest jobs :)""\e[0m"
system 'rubocop -a -x converted.rb'
