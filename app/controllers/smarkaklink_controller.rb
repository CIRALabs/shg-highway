require 'multipart_body'

# use of ActionController::Metal means that JSON parameters are
# not automatically parsed, which reduces cases of processing bad
# JSON when no JSON is acceptable anyway.
class SmarkaklinkController < ApiController

  def enroll
    clientcert  = nil
    @replytype  = request.content_type
    @clientcert = capture_client_certificate

    # params in application/json will get parsed automatically, no need
    # to do anything.
    # the posted certificate will in most cases be identical
    # to the TLS Client Certificate.
    # note: the lookup is by *PUBLIC KEY*, not certificate.

    if params[:cert]
      @owner = Owner.find_or_create_by_base64_certificate(params[:cert])

      @cert = @owner.sign_with_idevid_ca
      send_data @cert.to_der, :type => 'application/pkcs7'

    else
      capture_bad_request
      logger.error "enrollment failed for #{request.ip}, no certificate provided"
      head 406, text: "missing certificate"
    end
  end

  def provision
    if devnum=params['wan-mac']
      @device = Device.find_by_number(devnum) || Device.find_by_second_eui64(devnum)
    end
    if !@device and devnum=params['switch-mac']
      devnum  = Device.canonicalize_eui64(devnum)
      @device = Device.find_by_number(devnum) || Device.find_by_second_eui64(devnum)
    end
    unless @device
      num = ''
      if $TOFU_DEVICE_REGISTER
        attrs = Hash.new
        attrs['register_ip'] = request.env["REMOTE_ADDR"]
        attrs['tofu_register'] = true
        @device = Device.create(eui64: Device.canonicalize_eui64(params['wan-mac']),
                      second_eui64: Device.canonicalize_eui64(params['switch-mac']),
                      obsolete: true,        # mark it has not valid.
                      extra_attrs: attrs)
        num = @device.id
      end
      head 404, text: "device not known here #{num}"
      return
    end

    # found a device, collect the information about it!
    @device.eui64 = params['wan-mac']
    @device.second_eui64 = params['switch-mac']
    @device.ula   = params['ula']
    @csr64 = params['csr']

    # now create a private certificate from this CSR.
    @device.sign_from_base64_csr(@csr64)

    tgzfile = @device.generate_tgz_for_shg
    send_file tgzfile, :type => 'application/tar+gzip'
  end

  private

  def capture_client_certificate
    clientcert_pem = request.env["SSL_CLIENT_CERT"]
    clientcert_pem ||= request.env["rack.peer_cert"]
    clientcert_pem
  end

  # not sure how/where to capture bad requests
  def capture_bad_request
    junk = Base64.decode64(request.body.read)
    logger.info "Bad owner enrollment: #{junk}"
    head 406
  end

end