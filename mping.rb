#!/usr/bin/ruby

#多IP探测小程序
class MultiPingTask

  IP_REG          = /^(\d{1,2}|1\d\d|2[0-4]\d|25[0-5])\.(\d{1,2}|1\d\d|2[0-4]\d|25[0-5])\.(\d{1,2}|1\d\d|2[0-4]\d|25[0-5])\.(\d{1,2}|1\d\d|2[0-4]\d|25[0-5])$/
  IP_PIECE_REG    = /^(\d{1,2}|1\d\d|2[0-4]\d|25[0-5])(\.(\d{1,2}|1\d\d|2[0-4]\d|25[0-5])){0,3}$/
  SHORT_PARAM_REG = /^-[aodfsh]{2,6}$/

  def initialize(cmd_params)
    @ip_addrs       = []
    @result_hash    = {}
    @available_hash = {}
    @occupied_hash  = {}
    @params         = {}
    @stdout_mutex   = Mutex.new
    @test_count     = 4
    @max_length     = 0
    @help_text      = define_help_text
    if os_family == 'windows'
      @conf_filename = "#{`echo %userprofile%`.chomp}/.multi_ping_conf"
    else
      @conf_filename = "#{`echo ~`.chomp}/.multi_ping_conf"
    end
    deal_params(cmd_params)
  end

  #执行过程
  def run_prog
    #处理帮助请求
    if @params[:help]
      puts text
      exit 0
    end

    #处理使用默认配置文件的情况
    if @params[:default] && File.file?(@conf_filename)
      get_ip_from_file(@conf_filename)
    end

    #处理使用指定配置文件的情况
    if @params[:conf]
      unless File.file?(@params[:conf])
        puts "Can't find #{@params}. No such file"
        exit 0
      end
      get_ip_from_file(@params[:conf])
    end

    #处理单个ip地址
    if @params[:single]
      @ip_addrs.concat(@params[:single])
    end

    #处理范围ip地址
    if @params[:range]
      @params[:range].each do |range|
        @ip_addrs.concat(get_ip_by_range(range[0], range[1]))
      end
    end

    #处理ip数量较大时确认
    if @ip_addrs.size > 20
      until @params[:force]
        puts 'The number of ip addrs is bigger than 20,continue?(y/n)'
        str = $stdin.gets.chomp
        case str
          when 'yes', 'y'
            break
          when 'no', 'n'
            exit 0
          else
            next
        end
      end
    end

    #对待测ip进行去重,排序
    @ip_addrs.uniq!
    @ip_addrs.sort

    #进行多线程ping
    if @ip_addrs.size == 0
      puts 'Please specify at least one ip address'
      exit 0
    end
    puts "working on #{@ip_addrs.size} hosts"
    threads = []
    case os_family
      when 'windows'
        cmd = 'ping -w 200 '
      else
        cmd = 'ping -w 4 '
    end
    @ip_addrs.each do |addr|
      threads << Thread.new {
        do_sys_ping(addr, cmd)
      }
    end

    #如果含有默认配置文件之外的内容,则更新默认配置文件
    if @params[:single] || @params[:range] || @params[:conf]
      File.open(@conf_filename, 'w') do |f|
        @ip_addrs.each do |ip|
          f.puts ip
        end
      end
    end

    #等待所有线程执行完毕
    until @available_hash.size+@occupied_hash.size == @ip_addrs.size
      sleep(0.2)
    end

    #如果有排序需求则按排序后的顺序输出
    if @params[:sort]
      @ip_addrs.each do |ip|
        puts sprintf("%-#{@max_length}.#{@max_length}s: %s", ip, @result_hash[ip])
      end
    else
      if @params[:available]
        print_result(@available_hash)
      end
      if @params[:occupied]
        print_result(@occupied_hash)
      end
      unless @params[:available] || @params[:occupied]
        print_result(@available_hash)
        print_result(@occupied_hash)
      end
    end
  end

  private

  #处理参数
  def deal_params(cmd_params)
    if cmd_params.size == 0
      @params[:default] = true
      return
    end
    i = 0
    while i < cmd_params.size
      str = cmd_params[i]
      case str
        when SHORT_PARAM_REG
          short_param = str.split('')
          short_param.shift
          deal_params(short_param)
        when '-h', '--help', 'help', 'h'
          @params[:help] = true
          return
        when '-a', 'a'
          @params[:available]
        when '-o', 'o'
          @params[:occupied]
        when '-d', 'd'
          @params[:default] = true
        when '-f', 'f'
          @params[:force] = true
        when '-s', 's'
          @params[:sort] = true
        when '-c'
          @params[:conf] = cmd_params[i+1]
          i              += 1
        when IP_REG
          unless @params[:single]
            check_max_length(str)
            @params[:single] = []
          end
          @params[:single] << str
        else
          ip_range = str.split('-')
          unless ip_range.size == 2 && ip_range[0] =~ IP_REG && ip_range =~ IP_PIECE_REG
            puts "illegal param: \"#{str}\""
            exit 0
          end
          head = ip_range[0].split('.')
          tail = ip_range[1].split('.')
          if tail.size < 4
            tail.unshift(head[0..(3-tail.size)])
          end
          tail.flatten!
          @params[:range] = []
          @params[:range] << [ip_range[0], tail.join('.')]
      end
      i += 1
    end
  end

  #打印结果
  def print_result(hash)
    hash.each do |ip, result|
      puts sprintf("%-#{@max_length}.#{@max_length}s: %s", ip, result)
    end
  end

  #通过给定的范围,获取范围内所有的ip地址
  def get_ip_by_range(head, tail)
    arr_head  = head.split('.')
    arr_tail  = tail.split('.')
    long_head = 16777216*arr_head[0].to_i + 65536*arr_head[1].to_i + 256*arr_head[2].to_i + arr_head[3].to_i
    long_tail = 16777216*arr_tail[0].to_i + 65536*arr_tail[1].to_i + 256*arr_tail[2].to_i + arr_tail[3].to_i
    if long_tail < long_head
      long_head, long_tail = long_tail, long_head
    end
    ip_addresses = []
    (long_head...long_tail).each do |long|
      ip = []
      ip << long/16777216
      ip << long%16777216/65536
      ip << long%16777216%65536/256
      ip << long%16777216%65536%256
      str = "#{ip[0]}.#{ip[1]}.#{ip[2]}.#{ip[3]}"
      check_max_length(str)
      ip_addresses << str
    end
    check_max_length(tail)
    ip_addresses << tail
    ip_addresses
  end

  #读取指定的配置文件内容
  def get_ip_from_file(filename)
    f = File.open(filename, 'r')
    f.each_line do |line|
      line.chomp!
      ip_range = line.split('-')
      case ip_range.size
        when 0
          next
        when 1
          unless line =~ IP_REG
            puts "#{line} is not an ip address,ignored"
            next
          end
          check_max_length(line)
          @ip_addrs << line
        else
          unless ip_range[0] =~ IP_REG || ip_range[ip_range.size - 1] =~ IP_REG
            puts "#{line} contains illegal ip address,line ignored"
            next
          end
          @ip_addrs.concat(get_ip_by_range(ip_range[0], ip_range[ip_range.size - 1]))
      end
    end
  end

  def check_max_length(ip)
    @max_length = ip.length if ip.length > @max_length
  end

  #使用系统ping命令
  def do_sys_ping(ip, cmd)
    count       = 0
    exec_result = `#{cmd} #{ip}`
    exec_result.gsub(/ttl=\d{2}/i) do |m|
      count += 1
      m
    end
    if count > 0
      @occupied_hash[ip] = '× occupied'
    else
      @available_hash[ip] = '√ available'
    end
  end


  #判断操作系统类型
  def os_family
    RbConfig
    case RUBY_PLATFORM
      when /ix/i, /ux/i, /gnu/i,
          /sysv/i, /solaris/i,
          /sunos/i, /bsd/i
        'unix'
      when /win/i, /ming/i
        'windows'
      else
        'other'
    end
  end

  def define_help_text
    @help_text = <<-HELP
  Usage:
    mping [options]

    A tool to test if the ips are occupied(use icmp).
    This prog uses the "ping" cmd to test if we can connect to a remote host.
    Result is like:
      200.200.137.21: × occupied
      200.200.137.22: √ available
    If it has no parameter the program will use default configure file

  Options:
    ip_start-ip_end
      test all ip addrs from ip_start to ip_end,if >20,you have to confirm it
    ip_address
      test single ip
    -c file
      use "file" as config file.Please fill each line with different ip addresses or range

  Additional Options:
    -a
      show only available ip addrs
    -o
      show only occupied ip addrs
    -f
      suppress warnings
    -s
      sort the ip-addresses
    -d
      use default config file.
      If there are more than one test option the program will add additional ip addrs to default config file
    -h --help
      show this help text
    HELP
    @help_text.chomp!
  end
end
task = MultiPingTask.new(ARGV)
task.run_prog