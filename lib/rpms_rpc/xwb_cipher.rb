# frozen_string_literal: true

module RpmsRpc
  # The traditional VistA/Kernel XWB substitution cipher — the client side of
  # $$ENCRYP^XUSRB1 (server decodes with $$DECRYP^XUSRB1).
  #
  # This is the ONE cipher the broker uses for every client-encrypted value:
  # the access;verify pair at sign-on (XUS AV CODE / CIANBRPC AUTH), the
  # option name for XWB CREATE CONTEXT, and electronic-signature codes
  # (ORWU VALIDSIG, TIU SIGN RECORD). Standalone module so API-layer code
  # without a Client instance can encrypt; Client#xwb_encrypt delegates here.
  #
  # Wire format: `char(rowA+32) + substituted-body + char(rowB+32)` — each
  # body character is looked up in row A and replaced by the same-index
  # character of row B; characters not present in row A pass through.
  module XwbCipher
    # Cipher table pair source: XUSRB1.m (20 rows x 94 printable characters).
    TABLE = [
      'wkEo-ZJt!dG)49K{nX1BS$vH<&:Myf*>Ae0jQW=;|#PsO`\'%+rmb[gpqN,l6/hFC@DcUa ]z~R}"V\\iIxu?872.(TYL5_3',
      'rKv`R;M/9BqAF%&tSs#Vh)dO1DZP> *fX\'u[.4lY=-mg_ci802N7LTG<]!CWo:3?{+,5Q}(@jaExn$~p\\IyHwzU"|k6Jeb',
      '\\pV(ZJk"WQmCn!Y,y@1d+~8s?[lNMxgHEt=uw|X:qSLjAI*}6zoF{T3#;ca)/h5%`P4$r]G\'9e2if_>UDKb7<v0&- RBO.',
      'depjt3g4W)qD0V~NJar\\B "?OYhcu[<Ms%Z`RIL_6:]AX-zG.#}$@vk7/5x&*m;(yb2Fn+l\'PwUof1K{9,|EQi>H=CT8S!',
      'NZW:1}K$byP;jk)7\'`x90B|cq@iSsEnu,(l-hf.&Y_?J#R]+voQXU8mrV[!p4tg~OMez CAaGFD6H53%L/dT2<*>"{\\wI=',
      'vCiJ<oZ9|phXVNn)m K`t/SI%]A5qOWe\\&?;jT~M!fz1l>[D_0xR32c*4.P"G{r7}E8wUgyudF+6-:B=$(sY,LkbHa#\'@Q',
      'hvMX,\'4Ty;[a8/{6l~F_V"}qLI\\!@x(D7bRmUH]W15J%N0BYPkrs&9:$)Zj>u|zwQ=ieC-oGA.#?tfdcO3gp`S+En K2*<',
      'jd!W5[];4\'<C$/&x|rZ(k{>?ghBzIFN}fAK"#`p_TqtD*1E37XGVs@0nmSe+Y6Qyo-aUu%i8c=H2vJ\\) R:MLb.9,wlO~P',
      '2ThtjEM+!=xXb)7,ZV{*ci3"8@_l-HS69L>]\\AUF/Q%:qD?1~m(yvO0e\'<#o$p4dnIzKP|`NrkaGg.ufCRB[; sJYwW}5&',
      'vB\\5/zl-9y:Pj|=(R\'7QJI *&CTX"p0]_3.idcuOefVU#omwNZ`$Fs?L+1Sk<,b)hM4A6[Y%aDrg@~KqEW8t>H};n!2xG{',
      'sFz0Bo@_HfnK>LR}qWXV+D6`Y28=4Cm~G/7-5A\\b9!a#rP.l&M$hc3ijQk;),TvUd<[:I"u1\'NZSOw]*gxtE{eJp|y (?%',
      'M@,D}|LJyGO8`$*ZqH .j>c~h<d=fimszv[#-53F!+a;NC\'6T91IV?(0x&/{B)w"]Q\\YUWprk4:ol%g2nE7teRKbAPuS_X',
      '.mjY#_0*H<B=Q+FML6]s;r2:e8R}[ic&KA 1w{)vV5d,$u"~xD/Pg?IyfthO@CzWp%!`N4Z\'3-(o|J9XUE7k\\TlqSb>anG',
      'xVa1\']_GU<X`|\\NgM?LS9{"jT%s$}y[nvtlefB2RKJW~(/cIDCPow4,>#zm+:5b@06O3Ap8=*7ZFY!H-uEQk; .q)i&rhd',
      'I]Jz7AG@QX."%3Lq>METUo{Pp_ |a6<0dYVSv8:b)~W9NK`(r\'4fs&wim\\kReC2hg=HOj$1B*/nxt,;c#y+![?lFuZ-5D}',
      'Rr(Ge6F Hx>q$m&C%M~Tn,:"o\'tX/*yP.{lZ!YkiVhuw_<KE5a[;}W0gjsz3]@7cI2\\QN?f#4p|vb1OUBD9)=-LJA+d`S8',
      'I~k>y|m};d)-7DZ"Fe/Y<B:xwojR,Vh]O0Sc[`$sg8GXE!1&Qrzp._W%TNK(=J 3i*2abuHA4C\'?Mv\\Pq{n#56LftUl@9+',
      '~A*>9 WidFN,1KsmwQ)GJM{I4:C%}#Ep(?HB/r;t.&U8o|l[\'Lg"2hRDyZ5`nbf]qjc0!zS-TkYO<_=76a\\X@$Pe3+xVvu',
      'yYgjf"5VdHc#uA,W1i+v\'6|@pr{n;DJ!8(btPGaQM.LT3oe?NB/&9>Z`-}02*%x<7lsqz4OS ~E$\\R]KI[:UwC_=h)kXmF',
      '5:iar.{YU7mBZR@-K|2 "+~`M%8sq4JhPo<_X\\Sg3WC;Tuxz,fvEQ1p9=w}FAI&j/keD0c?)LN6OHV]lGy\'$*>nd[(tb!#'
    ].freeze

    module_function

    # Encrypt plaintext with a random row pair (matches $$ENCRYP^XUSRB1).
    def encrypt(plaintext)
      ra = rand(0..19)
      rb = rand(1..19)
      rb = rand(1..19) while rb == ra
      row_a = TABLE[ra]
      row_b = TABLE[rb]
      result = (ra + 32).chr
      plaintext.each_char do |ch|
        idx = row_a.index(ch)
        result += idx.nil? ? ch : row_b[idx]
      end
      result + (rb + 32).chr
    end

    # Whether `value` is framed as ciphertext this module produced: the first
    # and last bytes name the two cipher rows, and #encrypt never picks the
    # same row twice.
    #
    # This is a FRAMING check, not a proof of encryption — the cipher carries
    # no integrity tag, so a cleartext string whose first and last bytes happen
    # to land in the row range (32..51, i.e. space through "3") frames as
    # valid and decrypts to garbage. That is exactly what the broker does with
    # it too, so callers treating a framing failure as "this was never
    # encrypted" are strictly safer than the server, never looser.
    def framed?(value)
      s = value.to_s
      return false if s.length < 2

      ra = s[0].ord - 32
      rb = s[-1].ord - 32
      (0..19).cover?(ra) && (0..19).cover?(rb) && ra != rb
    end

    # Decrypt a value produced by #encrypt (matches $$DECRYP^XUSRB1).
    # Used in tests to round-trip-verify outgoing encrypted params.
    def decrypt(ciphertext)
      return "" if ciphertext.nil? || ciphertext.length < 2

      ra = ciphertext[0].ord - 32
      rb = ciphertext[-1].ord - 32
      return "" unless (0..19).cover?(ra) && (0..19).cover?(rb)

      row_a = TABLE[ra]
      row_b = TABLE[rb]
      ciphertext[1..-2].each_char.map { |ch|
        idx = row_b.index(ch)
        idx.nil? ? ch : row_a[idx]
      }.join
    end
  end
end
