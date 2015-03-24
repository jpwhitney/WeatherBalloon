{{
  SPI interface routines for SD & SDHC & MMC cards

  Jonathan "lonesock" Dummer
  version 0.3.0  2009 July 19

  Using multiblock SPI mode exclusively.

  For the fsrw project:
  fsrw.sf.net
}}

CON
  ' possible card types
  type_MMC      = 1
  type_SD       = 2
  type_SDHC     = 3
  
  ' Error codes
  ERR_CARD_NOT_RESET            = -1
  ERR_3v3_NOT_SUPPORTED         = -2
  ERR_OCR_FAILED                = -3
  ERR_BLOCK_NOT_LONG_ALIGNED    = -4
  '...
  ' These errors are for the assembly engine...they are negated inside, and need to be <= 511
  ERR_ASM_NO_READ_TOKEN         = 100
  ERR_ASM_BLOCK_NOT_WRITTEN     = 101
  ' NOTE: errors -128 to -255 are reserved for reporting R1 response errors
  '...
  ERR_SPI_ENGINE_NOT_RUNNING    = -999
  ERR_CARD_BUSY_TIMEOUT          = -1000

  ' SDHC/SD/MMC command set for SPI
  CMD0    = $40+0        ' GO_IDLE_STATE 
  CMD1    = $40+1        ' SEND_OP_COND (MMC) 
  ACMD41  = $C0+41       ' SEND_OP_COND (SDC) 
  CMD8    = $40+8        ' SEND_IF_COND 
  CMD9    = $40+9        ' SEND_CSD 
  CMD10   = $40+10       ' SEND_CID 
  CMD12   = $40+12       ' STOP_TRANSMISSION
  CMD13   = $40+13       ' SEND_STATUS  
  ACMD13  = $C0+13       ' SD_STATUS (SDC)
  CMD16   = $40+16       ' SET_BLOCKLEN 
  CMD17   = $40+17       ' READ_SINGLE_BLOCK 
  CMD18   = $40+18       ' READ_MULTIPLE_BLOCK 
  CMD23   = $40+23       ' SET_BLOCK_COUNT (MMC) 
  ACMD23  = $C0+23       ' SET_WR_BLK_ERASE_COUNT (SDC)
  CMD24   = $40+24       ' WRITE_BLOCK 
  CMD25   = $40+25       ' WRITE_MULTIPLE_BLOCK 
  CMD55   = $40+55       ' APP_CMD 
  CMD58   = $40+58       ' READ_OCR
  CMD59   = $40+59       ' CRC_ON_OFF 

  ' buffer size for my debug cmd log
  'LOG_SIZE = 256<<1

{
VAR
  long SPI_engine_cog
  ' these are used for interfacing with the assembly engine | temporary initialization usage
  long SPI_command              ' "t", "r", "w", 0 =>done, <0 => error          | pin mask
  long SPI_block_index          ' which 512-byte block to read/write            | cnt at init
  long SPI_buffer_address       ' where to get/put the data in Hub RAM          | unused
'}
DAT
'' I'm placing these variables in a DAT section to make this driver a singleton.
'' If for some reason you really need more than one driver (e.g. if you have more
'' than a single SD socket), move these back into VAR.
SPI_engine_cog          long 0
' these are used for interfacing with the assembly engine | temporary initialization usage
SPI_command             long 0  ' "t", "r", "w", 0 =>done, <0 => error          | pin mask
SPI_block_index         long 0  ' which 512-byte block to read/write            | cnt at init
SPI_buffer_address      long 0  ' where to get/put the data in Hub RAM          | unused

{
VAR
  ' for debug ONLY
  byte log_cmd_resp[LOG_SIZE+1]
PUB get_log_pointer
  return @log_cmd_resp
'}
  
PUB start( basepin )
{{
  This is a compatibility wrapper, and requires that the pins be
  both consecutive, and in the order DO CLK DI CS.
}}
  return start_explicit( basepin, basepin+1, basepin+2, basepin+3 )

PUB readblock( block_index, buffer_address )
  if SPI_engine_cog == 0
    abort ERR_SPI_ENGINE_NOT_RUNNING
  if (buffer_address & 3)
    abort ERR_BLOCK_NOT_LONG_ALIGNED
  SPI_block_index := block_index
  SPI_buffer_address := buffer_address
  SPI_command := "r"
  repeat while SPI_command == "r"
  if SPI_command < 0
    abort SPI_command

PUB writeblock( block_index, buffer_address )
  if SPI_engine_cog == 0
    abort ERR_SPI_ENGINE_NOT_RUNNING
  if (buffer_address & 3)
    abort ERR_BLOCK_NOT_LONG_ALIGNED
  SPI_block_index := block_index
  SPI_buffer_address := buffer_address
  SPI_command := "w"
  repeat while SPI_command == "w"
  if SPI_command < 0
    abort SPI_command

PUB get_seconds
  if SPI_engine_cog == 0
    abort ERR_SPI_ENGINE_NOT_RUNNING
  SPI_command := "t"
  repeat while SPI_command == "t"
  ' secods are in SPI_block_index, remainder is in SPI_buffer_address
  return SPI_block_index

PUB get_milliseconds : ms
  if SPI_engine_cog == 0
    abort ERR_SPI_ENGINE_NOT_RUNNING
  SPI_command := "t"
  repeat while SPI_command == "t"
  ' secods are in SPI_block_index, remainder is in SPI_buffer_address
  ms := SPI_block_index * 1000
  ms += SPI_buffer_address * 1000 / clkfreq
  
PUB start_explicit( DO, CLK, DI, CS ) : card_type | tmp, i
{{
  Do all of the card initialization in SPIN, then hand off the pin
  information to the assembly cog for hot SPI block R/W action!
}}
  ' Start from scratch
  stop
  ' clear my log buffer
  {
  bytefill( @log_cmd_resp, 0, LOG_SIZE+1 )
  dbg_ptr := @log_cmd_resp
  dbg_end := dbg_ptr + LOG_SIZE
  '}
  ' wait ~4 milliseconds
  waitcnt( 500 + (clkfreq>>8) + cnt )
  ' (start with cog variables, _BEFORE_ loading the cog)
  pinDO := DO
  maskDO := |< DO
  pinCLK := CLK
  pinDI := DI
  maskDI := |< DI
  maskCS := |< CS
  adrShift := 9 ' block = 512 * index, and 512 = 1<<9
  ' pass the output pin mask via the command register
  SPI_command := maskCS | (|<pinCLK) | maskDI
  dira |= SPI_command  
  ' get the card in a ready state: set DI and CS high, send => 74 clocks
  outa |= SPI_command
  repeat 4096
    outa[CLK]~~
    outa[CLK]~
  ' time-hack
  SPI_block_index := cnt
  ' reset the card
  tmp~
  repeat i from 0 to 9
    if tmp <> 1
      tmp := send_cmd_slow( CMD0, 0, $95 )
      if (tmp & 4)
        ' the card said CMD0 ("go idle") was invalid, so we're possibly stuck in read or write mode
        if i & 1
          ' exit multiblock read mode
          repeat 4
            read_32_slow        ' these extra clocks are required for some MMC cards
          send_slow( $FD, 8 )   ' stop token
          read_32_slow
          repeat while read_slow <> $FF
        else
          ' exit multiblock read mode
          send_cmd_slow( CMD12, 0, $61 )           
  if tmp <> 1
    ' the reset command failed!
    crash( ERR_CARD_NOT_RESET )
  ' Is this a SD type 2 card?
  if send_cmd_slow( CMD8, $1AA, $87 ) == 1
    ' Type2 SD, check to see if it's a SDHC card
    tmp := read_32_slow
  ' check the supported voltage
    if (tmp & $1FF) <> $1AA
      crash( ERR_3v3_NOT_SUPPORTED )
    ' try to initialize the type 2 card with the High Capacity bit
    repeat while send_cmd_slow( ACMD41, |<30, $77 )
    ' the card is initialized, let's read back the High Capacity bit
    if send_cmd_slow( CMD58, 0, $FD ) <> 0
      crash( ERR_OCR_FAILED )
    ' get back the data
    tmp := read_32_slow
    ' check the bit
    if tmp & |<30
      card_type := type_SDHC
      adrShift := 0
    else
      card_type := type_SD
  else
    ' Either a type 1 SD card, or it's MMC, try SD 1st
    if send_cmd_slow( ACMD41, 0, $E5 ) < 2
      ' this is a type 1 SD card (1 means busy, 0 means done initializing)
      card_type := type_SD
      repeat while send_cmd_slow( ACMD41, 0, $E5 )
    else
      ' mark that it's MMC, and try to initialize
      card_type := type_MMC
      repeat while send_cmd_slow( CMD1, 0, $F9 )
    ' some SD or MMC cards may have the wrong block size, set it here
    send_cmd_slow( CMD16, 512, $15 )
  ' card is mounted, make sure the CRC is turned off
  send_cmd_slow( CMD59, 0, $91 )
  '  check the status
  'send_cmd_slow( CMD13, 0, $0D )    
  ' done with the SPI bus for now
  outa |= maskCS
  ' set my counter modes for super fast SPI operation
  ' writing: NCO single-ended mode, output on DI
  writeMode := (%00100 << 26) | (DI << 0)
  ' reading
  'readMode := (%11000 << 26) | (DO << 9) | (CLK << 0)
  readMode := (%11000 << 26) | (DO << 0) | (CLK << 9)
  ' clock
  clockInMode := (%00110 << 26) | (CLK << 0) ' DUTY, 25% duty cycle
  ' clock
  clockOutMode := (%00100 << 26) | (CLK << 0) ' NCO, 50% duty cycle
  ' how many bytes (8 clocks, >>3) fit into 1/2 of a second (>>1), 4 clocks per instruction (>>2)?
  N_in8_500ms := clkfreq >> constant(1+2+3)
  ' Hand off control to the assembly engine's cog  
  bufAdr := @SPI_buffer_address
  sdAdr := @SPI_block_index
  ' get a copy of my pin mask (SPI_command will soon be overwritten)
  tmp := SPI_command  
  ' start my driver cog and wait till I hear back that it's done 
  SPI_engine_cog := cognew( @SPI_engine_entry, @SPI_command ) + 1
  if( SPI_engine_cog == 0 )
    dira &= !tmp
    abort ERR_SPI_ENGINE_NOT_RUNNING
  repeat while SPI_command <> 1
  ' and we no longer need to control any pins from here
  dira &= !tmp
  ' let the PASM driver know it can continue
  SPI_command := 0
  ' the return variable is card_type   

PUB release
{{
  I do not want to abort if the cog is not
  running, as this is called from stop, which
  is called from start/ [8^)  
}}
  if SPI_engine_cog
    SPI_command := "z"
    repeat while SPI_command == "z"
    
PUB stop
{{
  kill the assembly driver cog.
}}
  release
  if SPI_engine_cog
    cogstop( SPI_engine_cog~ - 1 )

PRI crash( abort_code )
{{
  In case of Bad Things(TM) happening,
  exit as gracefully as possible.
}}
  ' and we no longer need to control any pins from here
  dira &= !SPI_command
  ' and report our error
  abort abort_code

PRI send_cmd_slow( cmd, val, crc ) : reply | time_stamp
{{
  Send down a command and return the reply.
  Note: slow is an understatement!
  Note: this uses the assembly DAT variables for pin IDs,
  which means that if you run this multiple times (say for
  multiple SD cards), these values will change for each one.
  But this is OK as all of these functions will be called
  during the initialization only, before the PASM engine is
  running.
}}
  ' if this is an application specific command, handle it
  if (cmd & $80)
    ' ACMD<n> is the command sequense of CMD55-CMD<n>
      cmd &= $7F
      reply := send_cmd_slow( CMD55, 0, $65 )
      if (reply > 1)
        return reply  
  ' the CS line needs to go low during this operation
  outa |= maskCS
  outa &= !maskCS
  ' give the card a few cocks to finish whatever it was doing
  read_32_slow
  ' send the command byte
  send_slow( cmd, 8 )
  ' send the value long
  send_slow( val, 32 )   
  ' send the CRC byte
  send_slow( crc, 8 )
  ' is this a CMD12?, if so, stuff byte
  if cmd == CMD12
    read_slow
  ' read back the response (spec declares 1-8 reads max for SD, MMC is 0-8)
  time_stamp := 9
  repeat
    reply := read_slow
  while( reply & $80 ) and ( time_stamp-- )
  ' done, and 'reply' is already pre-loaded
  {
  if dbg_ptr < (dbg_end-1)
    byte[dbg_ptr++] := cmd
    byte[dbg_ptr++] := reply
    if (cmd&63) == 13
      ' get the second byte
      byte[dbg_ptr++] := cmd
      byte[dbg_ptr++] := read_slow
  '}  

PRI send_slow( value, bits_to_send )
  value ><= bits_to_send
  repeat bits_to_send
    outa[pinCLK]~
    outa[pinDI] := value
    value >>= 1
    outa[pinCLK]~~

PRI read_32_slow : r
  repeat 4
    r <<= 8
    r |= read_slow
  
PRI read_slow : r
{{
  Read back 8 bits from the card
}}
  ' we need the DI line high so a read can occur
  outa[pinDI]~~
  ' get 8 bits (remember, r is initialized to 0 by SPIN)
  repeat 8
    outa[pinCLK]~
    outa[pinCLK]~~
    r += r + ina[pinDO]
  ' error check
  if( (cnt - SPI_block_index) > (clkfreq << 2) )
    crash( ERR_CARD_BUSY_TIMEOUT )
   
DAT
{{
        This is the assembly engine for doing fast block
        reads and writes.  This is *ALL* it does!
}}
ORG 0
SPI_engine_entry
        ' Counter A drives data out
        mov ctra,writeMode
        ' Counter B will always drive my clock line
        mov ctrb,clockOutMode
        ' the command register (par) holds the pin mask
        rdlong dira,par
        ' handshake that we now control the pins
        mov tmp1,#1
        wrlong tmp1,par
        ' handshake that we can continue
:cmd_not_at_0
        rdlong tmp1,par wz
if_nz   jmp #:cmd_not_at_0
        ' start my seconds' counter here
        mov last_time,cnt
        ' let the initializer know we're done
        mov user_cmd,#0   
        wrlong user_cmd,par
        
waiting_for_command
        call #count_seconds
        ' read the command, and make sure it's from the user (> 0)
        rdlong user_cmd,par
        cmps user_cmd,#0 wz,wc
if_be   jmp #waiting_for_command
        ' time requests are handled differently
        cmp user_cmd,#"t" wz    ' time
if_z    wrlong seconds,sdAdr    ' seconds goes into the SD index register
if_z    wrlong dtime,bufAdr     ' the remainder goes into the buffer address register        
        ' now, it's a user command, but we only accept two, filter for those
        cmp user_cmd,#"r" wz    ' read
if_nz   cmp user_cmd,#"w" wz    ' write
if_nz   cmp user_cmd,#"z" wz    ' terminate
if_nz   mov user_cmd,#0         ' nope, clear it
if_nz   jmp #:finish_command    ' and let's get back to business  
        ' OK, valid command, get the block index for this command
        rdlong user_idx,sdAdr
        ' Can we stay in the old mode? (address = old_address+1) && (old mode == new_mode)
        cmp lastIndexPlus,user_idx wz
if_z    cmp user_cmd,lastCommand wz
if_z    jmp #:execute_block_command
        ' we fell through, must exit the old mode!
        cmp lastCommand,#"w" wz
if_z    call #stop_mb_write
        cmp lastCommand,#"r" wz  
if_z    call #stop_mb_read
        ' and start up the new mode!
        cmp user_cmd,#"w" wz
if_z    call #start_mb_write
        cmp user_cmd,#"r" wz
if_z    call #start_mb_read
:execute_block_command
        ' track the (new) last index and command
        mov lastIndexPlus,user_idx
        add lastIndexPlus,#1
        mov lastCommand,user_cmd
        ' do the block read or write or terminate!
        cmp user_cmd,#"w" wz
if_z    call #write_single_block
        cmp user_cmd,#"r" wz
if_z    call #read_single_block
        cmp user_cmd,#"z" wz
if_z    call #release_DO 
        ' done
:finish_command
        wrlong user_cmd,par
        jmp #waiting_for_command


{=== these PASM functions get me in and out of multiblock mode ===}
start_mb_read
        movi block_cmd,#CMD18<<1
        call #send_SPI_command_fast       
start_mb_read_ret
        ret

stop_mb_read
        movi block_cmd,#CMD12<<1
        'mov user_idx,#0
        call #send_SPI_command_fast
        call #busy_fast
        'rdlong user_idx,sdAdr
stop_mb_read_ret
        ret

start_mb_write
        movi block_cmd,#CMD25<<1
        call #send_SPI_command_fast
start_mb_write_ret
        ret

stop_mb_write
        call #busy_fast
        ' only some cards need these extra clocks
        mov tmp1,#16
:loopity
        call #in8         
        djnz tmp1,#:loopity
        ' done with hack
        movi phsa,#$FD<<1
        call #out8
        call #in8       ' stuff byte
        call #busy_fast
stop_mb_write_ret
        ret

release_DO
        ' we're already out of multiblock mode, so
        ' deselect the card and send out some clocks
        or outa,maskCS
        call #in8
        call #in8
        ' flag that we're done        
        mov user_cmd,#0
release_DO_ret
        ret

send_SPI_command_fast
        ' make sure the CS line transitions low
        or outa,maskCS  
        andn outa,maskCS
        ' 8 clocks
        call #in8 
        ' send the data
        mov phsa,block_cmd                      ' do which ever block command this is (already in the top 8 bits)
        call #out8                               ' write the byte
        mov phsa,user_idx                       ' read in the desired block index
        shl phsa,adrShift                       ' this will multiply by 512 (bytes/sector) for MMC and SD
        call #out8                               ' move out the 1st MSB                              '
        rol phsa,#1
        call #out8                               ' move out the 1st MSB                              '
        rol phsa,#1
        call #out8                               ' move out the 1st MSB                              '
        rol phsa,#1
        call #out8                               ' move out the 1st MSB                              '
        ' bogus CRC value
        call #in8                                ' in8 looks like out8 with $FF
        ' CMD12 requires a stuff byte
        shr block_cmd,#24
        cmp block_cmd,#CMD12 wz
if_z    call #in8                               ' 8 clocks
        ' get the response
        mov tmp1,#9
:cmd_response
        call #in8
        test readback,#$80 wc,wz
if_c    djnz tmp1,#:cmd_response
if_nz   neg user_cmd,readback
        ' done        
send_SPI_command_fast_ret
        ret    
                        
        
busy_fast
        mov tmp1,N_in8_500ms
:still_busy
        call #in8
        cmp readback,#$FF wz
if_nz   djnz tmp1,#:still_busy
busy_fast_ret
        ret


out8
        andn outa,maskDI
        mov phsb,#0  
        movi frqb,#%010000000
        rol phsa,#1
        rol phsa,#1
        rol phsa,#1
        rol phsa,#1
        rol phsa,#1
        rol phsa,#1
        rol phsa,#1
        mov frqb,#0
        ' don't shift out the final bit...already sent, but be aware 
        ' of this when sending consecutive bytes (send_cmd, for e.g.) 
out8_ret
        ret


in8
        or outa,maskDI
        mov readback,#0
        ' set up my clock, and start it
        movi phsb,#%011_000000
        movi frqb,#%001_000000
        ' keep reading in my value
        test maskDO,ina wc
        rcl readback,#1
        test maskDO,ina wc
        rcl readback,#1
        test maskDO,ina wc
        rcl readback,#1
        test maskDO,ina wc
        rcl readback,#1
        test maskDO,ina wc
        rcl readback,#1
        test maskDO,ina wc
        rcl readback,#1
        test maskDO,ina wc
        rcl readback,#1
        test maskDO,ina wc
        mov frqb,#0 ' stop the clock
        rcl readback,#1
in8_ret
        ret
        
        
' this is called more frequently than 1 Hz
count_seconds        
        mov tmp1,cnt            ' get the current timestamp        
        add dtime,tmp1          ' add to my accumulator, 
        sub dtime,last_time     ' and subtract the old (adding delta)
        mov last_time,tmp1      ' update my "last timestamp"        
        rdlong tmp1,#0          ' what is the clock frequency?
        cmpsub dtime,tmp1 wc    ' if I have more than a second in my accumulator
        addx seconds,#0         ' then add it to "seconds"
count_seconds_ret
        ret
             

read_single_block
        ' where am I sending the data?
        rdlong buf_ptr,bufAdr
        mov ops_left,#128
        ' wait until the card is ready
        mov tmp1,N_in8_500ms
:get_resp
        call #in8
        cmp readback,#$FE wz        
if_nz   djnz tmp1,#:get_resp
if_nz   neg user_cmd,#ERR_ASM_NO_READ_TOKEN  
if_nz   jmp #read_single_block_ret
        {
        ' set up my clock counter
        movi phsb,#%011_000000           
:read_loop        
        ' Start my clock
        movi frqb,#%001_000000
        ' keep reading in my value, BACKWARDS!  (Brilliant idea by Tom Rokicki!)
        test maskDO,ina wc
        rcl readback,#8
        test maskDO,ina wc
        muxc readback,#2
        test maskDO,ina wc
        muxc readback,#4
        test maskDO,ina wc
        muxc readback,#8
        test maskDO,ina wc
        muxc readback,#16
        test maskDO,ina wc
        muxc readback,#32
        test maskDO,ina wc
        muxc readback,#64
        test maskDO,ina wc
        muxc readback,#128
        ' next byte
        test maskDO,ina wc
        rcl readback,#8
        test maskDO,ina wc
        muxc readback,#2
        test maskDO,ina wc
        muxc readback,#4
        test maskDO,ina wc
        muxc readback,#8
        test maskDO,ina wc
        muxc readback,#16
        test maskDO,ina wc
        muxc readback,#32
        test maskDO,ina wc
        muxc readback,#64
        test maskDO,ina wc
        muxc readback,#128
        ' next byte
        test maskDO,ina wc
        rcl readback,#8
        test maskDO,ina wc
        muxc readback,#2
        test maskDO,ina wc
        muxc readback,#4
        test maskDO,ina wc
        muxc readback,#8
        test maskDO,ina wc
        muxc readback,#16
        test maskDO,ina wc
        muxc readback,#32
        test maskDO,ina wc
        muxc readback,#64
        test maskDO,ina wc
        muxc readback,#128
        ' final byte
        test maskDO,ina wc
        rcl readback,#8
        test maskDO,ina wc
        muxc readback,#2
        test maskDO,ina wc
        muxc readback,#4
        test maskDO,ina wc
        muxc readback,#8
        test maskDO,ina wc
        muxc readback,#16
        test maskDO,ina wc
        muxc readback,#32
        test maskDO,ina wc
        muxc readback,#64
        test maskDO,ina wc
        mov frqb,#0 ' stop the clock
        muxc readback,#128
        ' make it...NOT backwards [8^)
        rev readback,#0
        '}

        '{
        ' read the data
        mov ctra,readMode
        mov ctrb,clockInMode
        mov ops_left,#128
:read_loop        
        ' Start my clock
        mov frqa,#1<<7
        mov phsa,#0
        movi phsb,#%11_0000000
        movi frqb,#%01_0000000
        ' keep reading in my value, one bit at a time!  (Kuneko - "Wh)
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shl frqa,#15
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shl frqa,#15
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shl frqa,#15
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        shr frqa,#1
        mov frqb,#0 ' stop the clock
        mov readback,phsa       ' due to some counter weirdness, we need this mov
        '}
        
        wrlong readback,buf_ptr
        add buf_ptr,#4
        djnz ops_left,#:read_loop
        
        '{
        ' get out of our counter mode, but 
        mov phsb,#0     ' make sure we don't send any extra clocks
        mov frqa,#0     ' make sure we don't mess with the future data out
        mov phsa,#0     ' clear the DI line
        mov ctra,writeMode
        mov ctrb,clockOutMode
        '}
        
        ' now read 2 trailing bytes (CRC)
        call #in8      ' out8 is 2x faster than in8
        call #in8      ' and I'm not using the CRC anyway
        ' give an extra 8 clocks in case we pause for a long time
        call #in8       ' in8 looks like out8($FF)
        ' all done successfully
        mov user_cmd,#0               
read_single_block_ret
        ret          
        
write_single_block
        ' where am I getting the data? (all 512 bytes / 128 longs of it?)
        rdlong buf_ptr,bufAdr
        ' read in 512 bytes (128 longs) from Hub RAM and write it to the card
        mov ops_left,#128        
        ' just hold your horses  
        call #busy_fast 
        ' $FC for multiblock, $FE for single block
        movi phsa,#$FC<<1
        call #out8
        mov phsb,#0             ' make sure my clock accumulator is right
:write_loop
        ' read 4 bytes
        rdlong phsa,buf_ptr
        ' a long in LE order is DCBA
        rol phsa,#24            ' move A7 into position, so I can do the swizzled version
        movi frqb,#%010000000   ' start the clock (remember A7 is already in place)
        rol phsa,#1             ' A7 is going out, at the end of this instr, A6 is in place
        rol phsa,#1             ' A5
        rol phsa,#1             ' A4
        rol phsa,#1             ' A3
        rol phsa,#1             ' A2
        rol phsa,#1             ' A1
        rol phsa,#1             ' A0
        rol phsa,#17            ' B7
        rol phsa,#1             ' B6
        rol phsa,#1             ' B5
        rol phsa,#1             ' B4
        rol phsa,#1             ' B3
        rol phsa,#1             ' B2
        rol phsa,#1             ' B1
        rol phsa,#1             ' B0
        rol phsa,#17            ' C7
        rol phsa,#1             ' C6
        rol phsa,#1             ' C5
        rol phsa,#1             ' C4
        rol phsa,#1             ' C3
        rol phsa,#1             ' C2
        rol phsa,#1             ' C1
        rol phsa,#1             ' C0
        rol phsa,#17            ' D7
        rol phsa,#1             ' D6
        rol phsa,#1             ' D5
        rol phsa,#1             ' D4
        rol phsa,#1             ' D3
        rol phsa,#1             ' D2
        rol phsa,#1             ' D1
        rol phsa,#1             ' D0 will be in place _after_ this instruction
        mov frqb,#0             ' shuts the clock off, _after_ this instruction
        add buf_ptr,#4
        djnz ops_left,#:write_loop
        ' write out my two (bogus, using $FF) CRC bytes
        call #in8
        call #in8
        ' now read response (I need this response, so can't spoof using out8)
        call #in8
        and readback,#$1F
        cmp readback,#5 wz
if_z    mov user_cmd,#0 ' great
if_nz   neg user_cmd,#ERR_ASM_BLOCK_NOT_WRITTEN ' oops
        ' send out another 8 clocks
        call #in8      ' out8 looks like in8 (only 2x faster) because phsa is still $FFFFFFFF
        ' all done
write_single_block_ret
        ret

        
{=== Assembly Interface Variables ===}
pinDO         long 0    ' pin is controlled by a counter
pinCLK        long 0    ' pin is controlled by a counter
pinDI         long 0    ' pin is controlled by a counter
maskDO        long 0    ' mask for reading the DO line from the card
maskDI        long 0    ' mask for setting the pin high while reading  
maskCS        long 0    ' mask = (1<<pin), and is controlled directly
adrShift      long 9    ' will be 0 for SDHC, 9 for MMC & SD
bufAdr        long 0    ' where in Hub RAM is the buffer to copy to/from?
sdAdr         long 0    ' where on the SD card does it read/write?
writeMode     long 0    ' the counter setup in NCO single ended, clocking data out on pinDI
clockOutMode  long 0    ' the counter setup in NCO single ended, driving the clock line on pinCLK
N_in8_500ms   long 1_000_000 ' used for timeout checking in PASM
'{
readMode      long 0
clockInMode   long 0
'}

{=== Initialized PASM Variables ===}
seconds       long 0
dtime         long 0

{=== Multiblock State Machine ===}
lastIndexPlus long -1   ' state handler will check against lastIndexPlus, which will not have been -1
lastCommand   long 0    ' this will never be the lst command.

{=== Debug Logging Pointers ===}
{
dbg_ptr       long 0
dbg_end       long 0
'}

{=== Assembly Scratch Variables ===}
ops_left      res 1     ' used as a counter for bytes, words, longs, whatever (start w/ # byte clocks out)
readback      res 1     ' all reading from the card goes through here
tmp1          res 1     ' this may get used in all subroutines...don't use except in lowest 
user_cmd      res 1     ' the main command variable, read in from Hub: "r"-read single, "w"-write single
user_idx      res 1     ' the pointer to the Hub RAM where the data block is/goes
block_cmd     res 1     ' one of the SD/MMC command codes, no app-specific allowed
buf_ptr       res 1     ' moving pointer to the Hub RAM buffer
last_time     res 1     ' tracking the timestamp

{{
  496 longs is my total available space in the cog,
  and I want 128 longs for eventual use as one 512-
  byte buffer.   This gives me a total of 368 longs
  to use for umount, and a readblock and writeblock
  for both Hub RAM and Cog buffers.
}}
speed_buf     res 128   ' 512 bytes to be used for read-ahead / write-behind

FIT 496

''      MIT LICENSE
{{
'  Permission is hereby granted, free of charge, to any person obtaining
'  a copy of this software and associated documentation files
'  (the "Software"), to deal in the Software without restriction,
'  including without limitation the rights to use, copy, modify, merge,
'  publish, distribute, sublicense, and/or sell copies of the Software,
'  and to permit persons to whom the Software is furnished to do so,
'  subject to the following conditions:
'
'  The above copyright notice and this permission notice shall be included
'  in all copies or substantial portions of the Software.
'
'  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
'  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
'  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
'  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
'  CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
'  TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
'  SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
}}