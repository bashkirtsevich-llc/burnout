program burnout;

uses
  Windows,
  Messages;

// Small version of FastBMP  
const
  hSection = 0;

type
  TFColor = packed record
    b, g, r: Byte;
  end;
  PFColor = ^TFColor;

  TLine = array [0..0] of TFColor;
  PLine = ^TLine;
  TPLines = array [0..0] of PLine;
  PPLines = ^TPLines;

  TFastBMP = packed record
    Initialized: Boolean;
    Gap, // space between scanlines
    RowInc, // distance to next scanline
    Size, // size of Bits
    Width, Height: Integer;
    Pixels: PPLines;
    Bits: Pointer;
      
    Handle, hDC: Integer;
    bmInfo: TBitmapInfo;
    bmHeader: TBitmapInfoHeader;
  end;
  PFastBMP = ^TFastBMP;

procedure FastBMP_Initialize(const bmp: PFastBMP);
var
  i: Integer;
  x: Longint;
begin
  with bmp^ do
  begin
    Pixels := VirtualAlloc(nil, Height * SizeOf(PLine), MEM_COMMIT, PAGE_READWRITE);
    Gap := Width mod 4;
    RowInc := (Width * 3) + Gap;
    Size := RowInc * Height;
    x := Integer(Bits);
    for i := 0 to Height - 1 do
    begin
      Pixels[i] := Pointer(x);
      Inc(x, RowInc);
    end;
    hDC := CreateCompatibleDC(0);
    SelectObject(hDC, Handle);

    Initialized := true;
  end;
end;

procedure FastBMP_Create(const bmp: PFastBMP; const cx, cy: Integer);
begin
  with bmp^ do
  begin
    Width := cx;
    Height := cy;
    with bmHeader do
    begin
      biSize := SizeOf(bmHeader);
      biWidth := Width;
      biHeight := -Height;
      biPlanes := 1;
      biBitCount := 24;
      biCompression := BI_RGB;
    end;
    bmInfo.bmiHeader := bmHeader;
    Handle := CreateDIBSection(0, bmInfo, DIB_RGB_COLORS, Bits, hSection, 0);
    FastBMP_Initialize(bmp);
  end;
end;

procedure FastBMP_CreateFromhBmp(const bmp: PFastBMP; const hBmp: Integer);
var
  BmpRec: TBITMAP;
  memDC: Integer;
begin
  with bmp^ do
  begin
    GetObject(hBmp, SizeOf(BmpRec), @BmpRec);
    Width := BmpRec.bmWidth;
    Height := BmpRec.bmHeight;
    Size := ((Width * 3) + (Width mod 4)) * Height;
    with bmHeader do
    begin
      biSize := SizeOf(bmHeader);
      biWidth := Width;
      biHeight := -Height;
      biPlanes := 1;
      biBitCount := 24;
      biCompression := BI_RGB;
    end;
    bmInfo.bmiHeader := bmHeader;
    Handle := CreateDIBSection(0, bmInfo, DIB_RGB_COLORS, Bits, hSection, 0);
    memDC := GetDC(0);
    GetDIBits(memDC, hBmp, 0, Height, Bits, bmInfo, DIB_RGB_COLORS);
    ReleaseDC(0, memDC);
    FastBMP_Initialize(bmp);
  end;
end;

procedure FastBMP_Draw(const bmp: PFastBMP; const hDst, x, y: Integer);
begin
  with bmp^ do
    BitBlt(hDst, x, y, Width, Height, hDC, 0, 0, SRCCOPY);
end;

procedure FastBMP_Destroy(const bmp: PFastBMP);
begin
  with bmp^ do
  begin
    DeleteDC(hDC);
    DeleteObject(Handle);
    VirtualFree(Pixels, 0, MEM_RELEASE);
    Initialized := False;
  end;
end;
{end of FastBMP}

type
  TCallBackInfo = packed record
    InfoType: (itText, itImage);
    Data: Cardinal; // pChar or hDC
    X, Y, Size: Integer; // FontSize
    Color1,
    Color2: TFColor;
  end;
  PCallBackInfo = ^TCallBackInfo;

  TDllCallbackProc = function(const CallbackInfo: PCallBackInfo): Boolean; cdecl;
  TDllConfigProc = procedure(const hWnd: HWND); cdecl;

const
  FlameW = 255;
  FlameH = 255;
  WindowW = 255;
  WindowH = 200;

  TransparentColor = $FF00FF;

  BtnCloseLeft = WindowW-1-13;
  BtnCloseTop = 7;
  BtnCloseRight = BtnCloseLeft+6;
  BtnCloseBottom = BtnCloseTop+6;

  BtnConfigLeft = WindowW-1-21;
  BtnConfigTop = 7;
  BtnConfigRight = BtnConfigLeft+6;
  BtnConfigBottom = BtnConfigTop+6;

  TmrAlphaID = WM_USER + $30;
  TmrAlphaInterval = 30;
  AlphaDownStep = 1;
  AlphaUpStep = 8;
  MinAlpha = 160;
  MaxAlpha = 255;

  AppName: PChar = 'Burnout';

var
  WndClass: TWndClass;
  WndHandle: THandle;
  ScrRect: TRect;
  WndDC: HDC;
  WndMsg: TMsg;
  WndAlpha, WndAlphaPrev: Integer;
  //
  BurnThread: THandle;
  BurnThreadID: DWORD;
  Terminated: Boolean;
  //
  DllHandle: HMODULE;
  DllCallBack: TDllCallbackProc = nil;
  DllConfig: TDllConfigProc = nil;

procedure ShowLastOSError(const ALastError: Integer);
var
  text: array [0..255] of Char;
begin
  if ALastError <> 0 then
    FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM or FORMAT_MESSAGE_IGNORE_INSERTS or
      FORMAT_MESSAGE_ARGUMENT_ARRAY, nil, ALastError, 0, text, SizeOf(text), nil)
  else
    text := 'A call to an OS function failed';

  MessageBox(0, PChar(@text[0]), AppName, MB_OK or MB_ICONEXCLAMATION);
end;

function MainWndProc(hWnd: HWND; uMsg: UINT; wParam: WPARAM;
  lParam: lParam): LRESULT; stdcall;

  function MouseOnWindow: Boolean;
  var
    p: TPoint;
    place: TWindowPlacement;
  begin
    Result := GetCursorPos(p) and GetWindowPlacement(WndHandle, @place) and
      PtInRect(place.rcNormalPosition, p);
  end;

begin
  case uMsg of
    WM_DESTROY:
      PostQuitMessage(0);

    WM_LBUTTONDOWN:
      begin
        Result := 0;
        if (Word(lParam) >= BtnCloseLeft) and
           (Word(lParam) <= BtnCloseRight) and
           (Word(lParam shr 16) >= BtnCloseTop) and
           (Word(lParam shr 16) <= BtnCloseBottom) then
          SendMessage(hWnd, WM_SYSCOMMAND, SC_CLOSE, 0)
        else
        if (Word(lParam) >= BtnConfigLeft) and
           (Word(lParam) <= BtnConfigRight) and
           (Word(lParam shr 16) >= BtnConfigTop) and
           (Word(lParam shr 16) <= BtnConfigBottom) then
        begin
          if Assigned(DllConfig) then DllConfig(WndHandle);
        end else
          Result := DefWindowProc(hWnd, WM_NCLBUTTONDOWN, HTCAPTION, lParam);

        Exit;
      end;

    WM_LBUTTONUP:
      begin
        Result := DefWindowProc(hWnd, WM_NCLBUTTONUP, HTCAPTION, lParam);
        Exit;
      end;

    WM_TIMER:
      if wParam = TmrAlphaID then
      begin
        if MouseOnWindow then
          inc(WndAlpha, AlphaUpStep)
        else
          Dec(WndAlpha, AlphaDownStep);

        if (WndAlpha > 255) then WndAlpha := 255;
        if (WndAlpha < MinAlpha) then WndAlpha := MinAlpha;

        if WndAlphaPrev <> WndAlpha then
          SetLayeredWindowAttributes(WndHandle, TransparentColor, WndAlpha,
            LWA_ALPHA or LWA_COLORKEY);

        WndAlphaPrev := WndAlpha;
      end;
  end;
  
  Result := DefWindowProc(hWnd, uMsg, wParam, lParam);
end;

function BurnThreadProc(lpParameter: Pointer): DWORD;

  function Rand(r: Integer): Integer; { Return a random number between -R And R }
  begin
    Result := Random(r * 2 + 1) - r;
  end;

const
  RootRand = 100; { Max/Min decrease of the root of the flames }
  Decay = 4; { How far should the flames go up on the screen? }
  { This MUST be positive - JF }
  MinY = 1; { Startingline of the flame routine.
    (should be adjusted along with MinY above) }
  Smooth = 5; { How descrete can the flames be? }
  MinFire = 80; { limit between the "starting to burn" and the "is burning" routines }
  { Startingpos on the screen, should be divideable by 4 without remain! }
  XStart = 1;
  XEnd = 255;
  Width = XEnd - XStart; 
  MaxColor = 190; { Constant for the MakePal procedure }
  FireIncrease = 25; { 3 = Wood, 90 = Gazolin }
  
var
  bmp: TFastBMP;
  Pal: array [0..255] of TFColor;
  Scr, scr2: array [0..FlameH, 0..FlameW] of Byte;
           
  procedure BurnInFlame(const srcbmp: PFastBMP; const x, y: Integer; const intensity: Integer);
  var
    cltmp: pfcolor;
    xx, yy, tmp: Integer;
  begin
    cltmp := srcbmp^.Bits;
    for yy := y to y + srcbmp^.height - 1 do
      for xx := x to x + srcbmp^.Width - 1 do
      begin
        if (xx < FlameH) and (yy < FlameW) then
        begin
          tmp := scr2[xx, yy] + (((cltmp.r + cltmp.g + cltmp.b) div 3) div intensity);

          if tmp > 255 then tmp := 255;

          if (yy < FlameW) and (xx < FlameH) and (xx > 0) and (yy > 0) then
            scr2[xx, yy] := tmp;
        end;

        Inc(cltmp);
      end;
  end;

  procedure DrawColor(const srcbmp: PFastBMP; const x, y: Integer;
    const ri, gi, bi: Single);
  var
    cltmp: pfcolor;
    xx, yy, tmp: Integer;
  begin
    cltmp := srcbmp^.Bits;
    for yy := y to y + srcbmp^.height - 1 do
      for xx := x to x + srcbmp^.Width - 1 do
      begin
        if (yy < FlameW) and (xx < FlameH) and (xx > 0) and (yy > 0) then
        begin
          if ri <> 0 then
          begin
            tmp := bmp.Pixels[yy, xx].r + (round(cltmp.r / ri));
            if tmp > 255 then tmp := 255;
            bmp.Pixels[yy, xx].r := tmp;
          end;

          if gi <> 0 then
          begin
            tmp := bmp.Pixels[yy, xx].g + (round(cltmp.g / gi));
            if tmp > 255 then tmp := 255;
            bmp.Pixels[yy, xx].g := tmp;
          end;

          if bi <> 0 then
          begin
            tmp := bmp.Pixels[yy, xx].b + (round(cltmp.b / bi));
            if tmp > 255 then tmp := 255;
            bmp.Pixels[yy, xx].b := tmp;
          end;
        end;
        Inc(cltmp);
      end;
  end;

  procedure MakePal;

    procedure Hsi2Rgb(const H, S, I: Single; var C: TFColor);
    { Convert (Hue, Saturation, Intensity) -> (RGB) }
    var
      T: Single;
      Rv, Gv, Bv: Single;
    begin
      T := H;
      Rv := 1 + S * Sin(T - 2 * Pi / 3);
      Gv := 1 + S * Sin(T);
      Bv := 1 + S * Sin(T + 2 * Pi / 3);
      T := 63.999 * I / 2;
      with C do
      begin
        r := trunc(Rv * T);
        g := trunc(Gv * T);
        b := trunc(Bv * T);
      end;
    end; { Hsi2Rgb }

  var
    i: Byte;
  begin
    FillChar(Pal, SizeOf(Pal), 0);
    for i := 1 to MaxColor do
      Hsi2Rgb(4.6 - 1.5 * i / MaxColor, i / MaxColor, i / MaxColor, Pal[i]);

    for i := MaxColor to 255 do
    begin
      Pal[i] := Pal[i - 1];
      with Pal[i] do
      begin
        if (r < 63)                   then Inc(r);
        if (i mod 2 = 0) and (g < 53) then Inc(g);
        if (i mod 2 = 0) and (b < 63) then Inc(b);
      end;
    end;

    for i := 0 to 255 do
    begin
      Pal[i].r := Pal[i].r * 4;
      Pal[i].g := Pal[i].g * 4;
      Pal[i].b := Pal[i].b * 4;

      if i < 60 then
      begin
        Pal[i].g := Pal[i].r;
        Pal[i].b := Pal[i].r;
      end;
    end;
  end;

  procedure Rectangle(const dstbmp: PFastBMP; const solid: Boolean;
    const x1, y1, x2, y2: Integer; const color: PFColor);
  var
    x, y: Integer;
  begin
    if x2 < x1 then
    asm
      push x1
      push x2
      pop x1
      pop x2
    end;

    if y2 < y1 then
    asm
      push y1
      push y2
      pop y1
      pop y2
    end;

    if solid then
    begin
      for x := x1 to x2 do
        for y := y1 to y2 do
          //with dstbmp^.Pixels[y, x] do begin r := cr; g := cg; b := cb; end;
          dstbmp^.Pixels[y, x] := color^;
    end else
    begin
      for x := x1 to x2 do
      begin
        //with dstbmp^.Pixels[y1, x] do begin r := cr; g := cg; b := cb; end;
        dstbmp^.Pixels[y1, x] := color^;
        //with dstbmp^.Pixels[y2, x] do begin r := cr; g := cg; b := cb; end;
        dstbmp^.Pixels[y2, x] := color^;
      end;
      for y := y1 to y2 do
      begin
        //with dstbmp^.Pixels[y, x1] do begin r := cr; g := cg; b := cb; end;
        dstbmp^.Pixels[y, x1] := color^;
        //with dstbmp^.Pixels[y, x2] do begin r := cr; g := cg; b := cb; end;
        dstbmp^.Pixels[y, x2] := color^;
      end;
    end;
  end;

  procedure DrawPixelText(const dstbmp: PFastBMP; solid: boolean;
    const text: PChar; const x, y, size: Integer; const color: PFColor);
  type
    TCharacter = packed record
      Character: Char;
      Code: Int64;
    end;

  const
    // compress it!
    Chars: array[0..92] of TCharacter =
      ((Character: '0'; Code: $0E11191513110E00),
       (Character: '1'; Code: $0E040404040C0400),
       (Character: '2'; Code: $1F10080601110E00),
       (Character: '3'; Code: $0E11010601110E00),
       (Character: '4'; Code: $02021F120A060200),
       (Character: '5'; Code: $0E11011E10101F00),
       (Character: '6'; Code: $0E11111E10080600),
       (Character: '7'; Code: $0808080402011F00),
       (Character: '8'; Code: $0E11110E11110E00),
       (Character: '9'; Code: $0C02010F11110E00),
       (Character: 'A'; Code: $11111F1111110E00),
       (Character: 'B'; Code: $1E11111E11111E00),
       (Character: 'C'; Code: $0E11101010110E00),
       (Character: 'D'; Code: $1E11111111111E00),
       (Character: 'E'; Code: $1F10101E10101F00),
       (Character: 'F'; Code: $1010101E10101F00),
       (Character: 'G'; Code: $0F11111710110E00),
       (Character: 'H'; Code: $1111111F11111100),
       (Character: 'I'; Code: $0E04040404040E00),
       (Character: 'J'; Code: $0E11110101010100),
       (Character: 'K'; Code: $1112141814121100),
       (Character: 'L'; Code: $1F10101010101000),
       (Character: 'M'; Code: $11111111151B1100),
       (Character: 'N'; Code: $1111111315191100),
       (Character: 'O'; Code: $0E11111111110E00),
       (Character: 'P'; Code: $1010101E11111E00),
       (Character: 'Q'; Code: $0D12151111110E00),
       (Character: 'R'; Code: $1111121E11111E00),
       (Character: 'S'; Code: $0E11010E10110E00),
       (Character: 'T'; Code: $0404040404041F00),
       (Character: 'U'; Code: $0E11111111111100),
       (Character: 'V'; Code: $040A111111111100),
       (Character: 'W'; Code: $0A15151515111100),
       (Character: 'X'; Code: $11110A040A111100),
       (Character: 'Y'; Code: $0404040A11111100),
       (Character: 'Z'; Code: $0F08080402010F00),
       (Character: 'a'; Code: $0F110F010E000000),
       (Character: 'b'; Code: $1E1111111E101000),
       (Character: 'c'; Code: $0E1110110E000000),
       (Character: 'd'; Code: $0F1111110F010100),
       (Character: 'e'; Code: $0E101E110E000000),
       (Character: 'f'; Code: $0404040F04040300),
       (Character: 'g'; Code: $0E010F11110F0000),
       (Character: 'h'; Code: $090909090E080800),
       (Character: 'i'; Code: $0C08080808000800),
       (Character: 'j'; Code: $0C12020206000200),
       (Character: 'k'; Code: $090A0C0A09080800),
       (Character: 'l'; Code: $0604040404040400),
       (Character: 'm'; Code: $111115151A000000),
       (Character: 'n'; Code: $090909090E000000),
       (Character: 'o'; Code: $0E1111110E000000),
       (Character: 'p'; Code: $101E1111111E0000),
       (Character: 'q'; Code: $010F1111110F0000),
       (Character: 'r'; Code: $1C08080916000000),
       (Character: 's'; Code: $0E010E100E000000),
       (Character: 't'; Code: $020504040F040000),
       (Character: 'u'; Code: $050B090909000000),
       (Character: 'v'; Code: $040A111111000000),
       (Character: 'w'; Code: $0A1F151111000000),
       (Character: 'x'; Code: $0909060909000000),
       (Character: 'y'; Code: $0C02070909090000),
       (Character: 'z'; Code: $0F0806010F000000),
       (Character: '!'; Code: $040004040E0E0400),
       (Character: '@'; Code: $0E10171517110E00),
       (Character: '#'; Code: $0A1F0A0A1F0A0000),
       (Character: '$'; Code: $020E010608070400),
       (Character: '%'; Code: $1313080402191900),
       (Character: '^'; Code: $00000000110A0400),
       (Character: '&'; Code: $0D12150814140800),
       (Character: '*'; Code: $000A0E1F0E0A0000),
       (Character: '('; Code: $0204040404040200),
       (Character: ')'; Code: $0804040404040800),
       (Character: '/'; Code: $0010080402010000),
       (Character: '-'; Code: $0000001F00000000),
       (Character: '_'; Code: $1F00000000000000),
       (Character: '+'; Code: $0004041F04040000),
       (Character: '='; Code: $001F00001F000000),
       (Character: ' '; Code: $0000000000000000),
       (Character: '{'; Code: $0304040C04040300),
       (Character: '}'; Code: $0C02020302020C00),
       (Character: '['; Code: $0704040404040700),
       (Character: ']'; Code: $0701010101010700),
       (Character: ';'; Code: $080C0C000C0C0000),
       (Character: ':'; Code: $0C0C000C0C000000),
       (Character: '''';Code: $0000000004060600),
       (Character: '"'; Code: $00000000121B1B00),
       (Character: ','; Code: $080C0C0000000000),
       (Character: '<'; Code: $0102040804020100),
       (Character: '.'; Code: $0C0C000000000000),
       (Character: '>'; Code: $0804020102040800),
       (Character: '?'; Code: $0400040601110E00),
       (Character: '`'; Code: $00000000000C1800),
       (Character: '~'; Code: $0000000000001F00)
      );

    function FindChar(const AChar: Char): TCharacter;
    var
      i: integer;
    begin
      for i := 0 to Length(Chars)-1 do
        if Chars[i].Character = AChar then
        begin
          Result := Chars[i];
          Exit;
        end;

      Result.Character := #0;
      Result.Code := 0;
    end;
    
  var
    c: TCharacter;
    i, j, k: Integer;
    b: Byte;
  begin
    for i := 0 to lstrlen(text)-1 do
    begin
      c := FindChar(text[i]);
      if c.Character = #0 then Continue;

      for j := 0 to 7 do
      begin
        b := Byte(c.Code);
        c.Code := c.Code shr 8;

        for k := 7 downto 3 do
        begin
          if b and 1 = 1 then
            Rectangle(dstbmp, solid, x+(k-3)*size+i*6*size,
                                     y+(j*size),
                                     x+(k-3)*size+i*6*size+size-1,
                                     y+(j*size)+size-1,
                                     color);
          b := b shr 1;
        end;
      end;
    end;
  end;

  procedure DrawInterface(const dstbmp: PFastBMP);
  type
    TRectangleRec = packed record
      solid: Boolean;
      x1, y1, x2, y2: Byte;
      color: TFColor;
    end;
    
    TTextRec = packed record
      text: PChar;
      x, y, size: Byte;
      color: TFColor;
    end;

  const
    // compress it!
    Rectangles: array[0..18] of TRectangleRec =
      ((solid: False; x1:           5; y1:           5; x2: WindowW-5-1; y2:          15; color: (b: $60; g: $90; r: $F7)), // title
       (solid: False; x1:           0; y1:           0; x2: WindowW-1  ; y2: WindowH-1  ; color: (b: $F7; g: $F7; r: $F7)),
       (solid: False; x1:           0; y1:           0; x2:           5; y2:           5; color: (b: $F7; g: $F7; r: $F7)), // white frame
       (solid: True ; x1:           0; y1:           0; x2:           4; y2:           4; color: (b: $FF; g: $00; r: $FF)), // transparent
       (solid: False; x1: WindowW-1-5; y1:           0; x2: WindowW-1  ; y2:           5; color: (b: $F7; g: $F7; r: $F7)), // frame
       (solid: True ; x1: WindowW-1-4; y1:           0; x2: WindowW-1  ; y2:           4; color: (b: $FF; g: $00; r: $FF)), // transparent
       (solid: False; x1:           0; y1: WindowH-1-5; x2:           5; y2: WindowH-1  ; color: (b: $F7; g: $F7; r: $F7)), // frame
       (solid: True ; x1:           0; y1: WindowH-1-4; x2:           4; y2: WindowH-1  ; color: (b: $FF; g: $00; r: $FF)), // transparent
       (solid: False; x1: WindowW-1-5; y1: WindowH-1-5; x2: WindowW-1  ; y2: WindowH-1  ; color: (b: $F7; g: $F7; r: $F7)), // frame
       (solid: True ; x1: WindowW-1-4; y1: WindowH-1-4; x2: WindowW-1  ; y2: WindowH-1  ; color: (b: $FF; g: $00; r: $FF)), // transparent

       (solid: True ; x1:           3; y1:           3; x2:           4; y2:           4; color: (b: $00; g: $00; r: $00)), // black point
       (solid: True ; x1: WindowW-1-4; y1:           3; x2: WindowW-1-2; y2:           4; color: (b: $00; g: $00; r: $00)), // black point
       (solid: True ; x1:           3; y1: WindowH-1-4; x2:           4; y2: WindowH-1-2; color: (b: $00; g: $00; r: $00)), // black point
       (solid: True ; x1: WindowW-1-4; y1: WindowH-1-4; x2: WindowW-1-2; y2: WindowH-1-2; color: (b: $00; g: $00; r: $00)), // black point

       (solid: False; x1:           2; y1:           2; x2: WindowW-2-1; y2: WindowH-2-1; color: (b: $00; g: $F7; r: $F7)), // yellow frame

       (solid: False; x1: BtnCloseLeft   ; y1: BtnCloseTop   ; x2: BtnCloseRight   ; y2: BtnCloseBottom   ; color: (b: $00; g: $00; r: $EF)), // close button
       (solid: True ; x1: BtnCloseLeft+2 ; y1: BtnCloseTop+2 ; x2: BtnCloseRight-2 ; y2: BtnCloseBottom-2 ; color: (b: $F0; g: $EF; r: $EF)), // close button

       (solid: False; x1: BtnConfigLeft  ; y1: BtnConfigTop  ; x2: BtnConfigRight  ; y2: BtnConfigBottom  ; color: (b: $00; g: $CF; r: $CF)), // config button
       (solid: True ; x1: BtnConfigLeft+2; y1: BtnConfigTop+2; x2: BtnConfigRight-2; y2: BtnConfigBottom-2; color: (b: $F0; g: $EF; r: $EF)) // config button
       );

     Texts: array[0..0] of TTextRec =
      ((text: 'BURNOUT v.0.1 by M.A.D.M.A.N. (2013)'; x: 7; y: 6; size: 1; color: (b: $10; g: $FF; r: $90))
       );

  var
    i: Integer;
    r: TRectangleRec;
    t: TTextRec;
  begin
    for i := 0 to Length(Rectangles) - 1 do
    begin
      r := Rectangles[i];
      Rectangle(dstbmp, r.solid,
        r.x1, r.y1+(FlameH-WindowH),
        r.x2, r.y2+(FlameH-WindowH),
        @r.color
      );
    end;

    for i := 0 to Length(Texts) - 1 do
    begin
      t := Texts[i];
      DrawPixelText(dstbmp, False, t.text,
        t.x, t.y+(FlameH-WindowH),
        t.size,
        @t.color
      );
    end;
  end;

  function Min(const a, b: Single): Single;
  begin
    if a > b then
      Result := b
    else
      Result := a;
  end;

const
  burnoutdef = 0.4;
  burnoutmax = 1.21;

var
  FlameArray: array [XStart .. XEnd] of Byte;
  I, J: Integer;
  x: Integer;
  MoreFire, V: Integer;
  bmpx, bmpy: Integer;
  
  infobmp: TFastBMP;
  burnoutreal: Single;
  dllInfo: TCallBackInfo;
  randVal: Integer;
begin
  infobmp.Initialized := False;
  randVal := -1;

  FastBMP_create(@bmp, FlameW + 1, FlameH + 1);
  try
    burnoutreal := burnoutdef;
    Randomize;
    MoreFire := 3;
    MakePal;

    { Initialize FlameArray }
    for I := XStart to XEnd do
      FlameArray[I] := 0;

    FillChar(Scr, SizeOf(Scr), 0); { Clear Screen }
    FillChar(scr2, SizeOf(scr2), 0); { Clear Screen }
    FillChar(FlameArray[XStart + Random(XEnd - XStart - 5)], 5, 25);
    repeat
      { Put the values from FlameArray on the bottom line of the screen }
      for I := XStart to XEnd do
        scr2[I, FlameH] := FlameArray[I];

      { This loop makes the actual flames }

      for I := XStart to XEnd do
        for J := MinY to FlameH do
        begin
          V := scr2[I, J];
          if (V = 0) or (V < Decay) or (I <= XStart) or (I >= XEnd) then
            scr2[I, Pred(J)] := 0
          else
            scr2[I - Pred(Random(3)), Pred(J)] := V - Random(Decay);
        end;

      if (Random(30) = 0) then
      begin
        FillChar(FlameArray[XStart + Random(XEnd - XStart - 5)], 5, 255);

        // Water effect
        for I := 1 to 40 do
          FlameArray[XStart + Random(XEnd)] := 0;
      end;

      { This loop controls the "root" of the
        flames ie. the values in FlameArray. }
      for I := XStart to XEnd do
      begin
        x := FlameArray[I];
        if x < MinFire then { Increase by the "burnability" }
        begin
          { Starting to burn: }
          if x > 10 then
            Inc(x, Random(FireIncrease));
        end else
          { Otherwise randomize and increase by intensity (is burning) }
          Inc(x, Rand(RootRand) + MoreFire);

        if x > 255 then
          x := 255; { X Too large ? }
        
        FlameArray[I] := x;
      end;

      { Smoothen the values of FrameArray to avoid "descrete" flames }
      for I := XStart + Smooth to XEnd - Smooth do
      begin
        x := 0;
      
        for J := -Smooth to Smooth do
          Inc(x, FlameArray[I + J]);

        FlameArray[I] := x div (2 * Smooth + 1);
      end;

      for bmpx := 0 to FlameW do
        for bmpy := 0 to FlameH do
          bmp.Pixels[bmpx, bmpy] := Pal[scr2[bmpy, bmpx]];

      //---
      // can load via callback
      if not infobmp.Initialized then
      begin
        if not (Assigned(DllCallBack) and DllCallBack(@dllInfo)) then
        begin
          with dllInfo do
          begin
            InfoType := itText;
            X := 24;
            Y := 150;
            Size := 3;

            //R1 := $AA; G1 := $96; B1 := $96; R2 := $FF; G2 := $AA; B2 := $AA;
            Int64((@Color1)^) := $0000AA9696FFAAAA;
          end;
          
          while randVal = Random(6) do;
          asm
            mov randVal, eax
          end;

          // 13 - string length (12 + #0)
          dllInfo.Data := Cardinal(PChar('  Burnout!  '#0+
                                         'M.A.D.M.A.N.'#0+
                                         '   Hello!   '#0+
                                         '   What?!   '#0+
                                         ' More flame '#0+
                                         ' FLAMEABLE! '#0))+(randVal*13);
        end;

        if dllInfo.InfoType = itText then
          FastBMP_Create(@infobmp, 6*lstrlen(PChar(dllInfo.Data))*dllInfo.Size, 8*dllInfo.Size)
        else
          FastBMP_CreateFromhBmp(@infobmp, dllInfo.Data);

        if dllInfo.Size >= 2 then
          DrawPixelText(@infobmp, True , PChar(dllInfo.Data), 0, 0, dllInfo.Size, @dllInfo.Color2);

        DrawPixelText(@infobmp, False, PChar(dllInfo.Data), 0, 0, dllInfo.Size, @dllInfo.Color1);
      end;

      if burnoutreal < burnoutmax then
        burnoutreal := burnoutreal + 0.001
      else
        burnoutreal := burnoutreal + 0.06;

      DrawColor  (@infobmp, dllInfo.X, dllInfo.Y+trunc(burnoutreal-burnoutmax), burnoutreal, burnoutreal*4, burnoutreal*4);
      BurnInFlame(@infobmp, dllInfo.X, dllInfo.Y+trunc(burnoutreal-burnoutmax), 134-trunc(Min(burnoutreal, burnoutmax)*100)+Rand(3));

      if burnoutreal > 20 then
      begin
        burnoutreal := burnoutdef;
        FastBMP_Destroy(@infobmp);
      end;
      //---
      
      DrawInterface(@bmp);

      FastBMP_Draw(@bmp, WndDC, 0, WindowH - FlameH);

      Sleep(12);
    until Terminated;
  finally
    FastBMP_Destroy(@bmp);
    
    if infobmp.Initialized then
      FastBMP_Destroy(@infobmp);
  end;
  Result := 0;
end;

const
  DLL_STRINGS_BURNOUT_DLL = 0;
  DLL_STRINGS_BURNOUT_CALLBACK = 12;
  DLL_STRINGS_BURNOUT_CONFIG = 29;
  DLL_STRINGS: PChar = 'burnout.dll'#0+
                       'BURNOUT_CallBack'#0+
                       'BURNOUT_Config'#0;
var
  ErrorCode: Integer;

label
  lShowErrorAndExit1, lShowErrorAndExit2, lShowErrorAndExit3,
  lThreadBlockEnd, lWindowBlockEnd;
begin
  DllHandle := LoadLibrary(PChar(Cardinal(DLL_STRINGS)+DLL_STRINGS_BURNOUT_DLL));
  if DllHandle <> 0 then
  begin
    DllCallBack := GetProcAddress(DllHandle, PChar(Cardinal(DLL_STRINGS)+DLL_STRINGS_BURNOUT_CALLBACK));
    DllConfig := GetProcAddress(DllHandle, PChar(Cardinal(DLL_STRINGS)+DLL_STRINGS_BURNOUT_CONFIG));
  end;

  ErrorCode := ERROR_SUCCESS;

  FillChar(WndClass, SizeOf(WndClass), 0);
  with WndClass do
  begin
//    Style := 0;
//    hIcon := 0;
    lpfnWndProc := @MainWndProc;
    hInstance := Sysinit.HInstance;
//    hbrBackground := 0;
    lpszClassName := AppName;
    hCursor := LoadCursor(0, IDC_ARROW);
  end;

  if (RegisterClass(WndClass) = 0) then
    ErrorCode := GetLastError;

  if ErrorCode <> ERROR_SUCCESS then goto lShowErrorAndExit1;

  if not SystemParametersInfo(SPI_GETWORKAREA, 0, @ScrRect, 0) then
    FillChar(ScrRect, SizeOf(ScrRect), 0);
    
  WndHandle := CreateWindowEx(WS_EX_TOPMOST or WS_EX_LAYERED or WS_EX_TOOLWINDOW,
                              AppName,
                              AppName,
                              WS_SYSMENU or WS_POPUP or WS_VISIBLE,
                              ScrRect.Right  - WindowW - 5,
                              ScrRect.Bottom - WindowH - 5,
                              WindowW, WindowH,
                              0, 0,
                              HInstance, nil);

  if WndHandle = 0 then
    goto lShowErrorAndExit2;

  WndAlpha := 255;
  WndAlphaPrev := -1;
  if not SetLayeredWindowAttributes(WndHandle, TransparentColor, WndAlpha,
    LWA_ALPHA or LWA_COLORKEY) then
    goto lShowErrorAndExit2;

  WndDC := GetDC(WndHandle);
  if WndDC = 0 then
    goto lShowErrorAndExit3;

  BurnThread := CreateThread(nil, 0, @BurnThreadProc, nil, 0, BurnThreadID);
  if BurnThread = INVALID_HANDLE_VALUE then
    goto lShowErrorAndExit3;

  if SetTimer(WndHandle, TmrAlphaID, TmrAlphaInterval, nil) = 0 then
    goto lShowErrorAndExit3;

  while GetMessage(WndMsg, 0, 0, 0) do
  begin
    TranslateMessage(WndMsg);
    DispatchMessage(WndMsg);
  end;

  Terminated := True;
  Sleep(500); // wait for therad exit

  goto lThreadBlockEnd;
  lShowErrorAndExit3: ErrorCode := GetLastError;

  lThreadBlockEnd:;
  ReleaseDC(WndHandle, WndDC);
  KillTimer(WndHandle, TmrAlphaID);

  goto lWindowBlockEnd;
  lShowErrorAndExit2: ErrorCode := GetLastError;

  lWindowBlockEnd:;
  UnregisterClass(AppName, HInstance);

  if DllHandle <> 0 then
    FreeLibrary(DllHandle);

  lShowErrorAndExit1:;
  if ErrorCode <> ERROR_SUCCESS then
    ShowLastOSError(ErrorCode);

end.

