OBJ

  pst :      "Parallax Serial Terminal"
  RC  :      "RCTIME"
  
CON                             'Global Constants

  _CLKMODE = XTAL1 + PLL16X      'Set to ext low-speed crystal, 4x PLL                           
  _XINFREQ = 5_000_000          'Set frequency to external crystals 5MHz speed


VAR                             'Variables

     long     Vertical           'GPS Coordinates - 100 bytes... To be adjusted
     long     Horizontal
     long     RCValue
     
Pub ReadJoystick

  {{Works with the RC circuit below:
  
          220Ω  C=.1uF
I/O Pin ──┳── GND
             │
           ┌R
           │ │
           └─┻─── GND

  }}

           
  pst.Start(115200)
  dira[0]~                               'Set pin 0 to input: Vertical Axis
  dira[1]~                               'Set pin 1 to input: Horizontail Axis
                             
 'Initialize Values
  Vertical   := 50
  Horizontal := 50
  

 repeat
    RC.RCTIME(5,1,@Vertical) 
    RC.RCTIME(6,1,@Horizontal)
    Vertical := (Vertical  + 33) / 33
    Horizontal := (Horizontal + 33) / 30
    
    pst.Str(string("Vertical: "))
    pst.Dec(Vertical)
    pst.NewLine
    
    pst.Str(string("Horizontal: "))
    pst.Dec(Horizontal)
    pst.NewLine
    
    WaitCnt(ClkFreq / 4 + Cnt)
   