program BLETest;
{$mode objfpc}{$H+}
//{$define show_data}

uses 
RaspberryPi3,HTTP,WebStatus,GlobalConfig,GlobalConst,GlobalTypes,Platform,Threads,SysUtils,
Classes,Console,Keyboard,Logging,Ultibo,Serial,BCM2710,FileSystem,SyncObjs;

const 
 HCI_COMMAND_PKT               = $01;
 HCI_EVENT_PKT                 = $04;
 FIRMWARE_START                = 100;
 FIRMWARE_END                  = 101;
 DELAY_50MSEC                  = 102;
 DELAY_2SEC                    = 103;
 INIT_COMPLETE                 = 104;
 FLUSH_PORT                    = 105;
 OPEN_PORT                     = 106;
 CLOSE_PORT                    = 107;
 SYSTEM_RESTART                = 109;
 OGF_MARKER                    = $00;
 OGF_HOST_CONTROL              = $03;
 OGF_INFORMATIONAL             = $04;
 OGF_VENDOR                    = $3f;

type 
 TBTMarkerEvent = procedure (no:integer);
 PQueueItem = ^TQueueItem;
 TQueueItem = record
  OpCode:Word;
  Params:array of byte;
  Prev,Next:PQueueItem;
 end;

var 
 FWHandle:integer; // firmware file handle
 RxBuffer:array of byte;
 HciSequenceNumber:Integer;
 Console1:TWindowHandle;
 ch : char;
 UART0:PSerialDevice = Nil;
 First:PQueueItem = Nil;
 Last:PQueueItem = Nil;
 ReadHandle:TThreadHandle = INVALID_HANDLE_VALUE;
 Queue:TMailslotHandle;
 QueueHandle:TThreadHandle = INVALID_HANDLE_VALUE;
 QueueEvent:TEvent;
 MarkerEvent:TBTMarkerEvent = Nil;
 MonitorReadExecuteHandle:TThreadHandle = INVALID_HANDLE_VALUE;
 HTTPListener:THTTPListener;

procedure Log(s : string);
begin
 ConsoleWindowWriteLn(Console1,s);
end;

procedure RestoreBootFile(Prefix,FileName: String);
var 
 Source:String;
begin
 Source:=Prefix + '-' + FileName;
 Log(Format('Restoring from %s ...',[Source]));
 while not DirectoryExists('C:\') do
  sleep(500);
 if FileExists(Source) then
  CopyFile(PChar(Source),PChar(FileName),False);
 Log(Format('Restoring from %s done',[Source]));
end;

function ogf(op:Word):byte;
begin
 Result:=(op shr 10) and $3f;
end;

function ocf(op:Word):Word;
begin
 Result:=op and $3ff;
end;

function ErrToStr(code:byte):string;
begin
 case code of 
  $00:Result:='Success';
  $01:Result:='Unknown HCI Command';
  $02:Result:='Unknown Connection Identifier';
  $03:Result:='Hardware Failure';
  $04:Result:='Page Timeout';
  $05:Result:='Authentication Failure';
  $06:Result:='PIN or Key Missing';
  $07:Result:='Memory Capacity Exceeded';
  $08:Result:='Connection Timeout';
  $09:Result:='Connection Limit Exceeded';
  $0A:Result:='Synchronous Connection Limit To A Device Exceeded';
  $0B:Result:='ACL Connection Already Exists';
  $0C:Result:='Command Disallowed';
  $0D:Result:='Connection Rejected due to Limited Resources';
  $0E:Result:='Connection Rejected due To Security Reasons';
  $0F:Result:='Connection Rejected due to Unacceptable BD_ADDR';
  $10:Result:='Connection Accept Timeout Exceeded';
  $11:Result:='Unsupported Feature or Parameter Value';
  $12:Result:='Invalid HCI Command Parameters';
  $13:Result:='Remote User Terminated Connection';
  $14:Result:='Remote Device Terminated Connection due to Low Resources';
  $15:Result:='Remote Device Terminated Connection due to Power Off';
  $16:Result:='Connection Terminated By Local Host';
  $17:Result:='Repeated Attempts';
  $18:Result:='Pairing Not Allowed';
  $19:Result:='Unknown LMP PDU';
  $1A:Result:='Unsupported Remote Feature / Unsupported LMP Feature';
  $1B:Result:='SCO Offset Rejected';
  $1C:Result:='SCO Interval Rejected';
  $1D:Result:='SCO Air Mode Rejected';
  $1E:Result:='Invalid LMP Parameters / Invalid LL Parameters';
  $1F:Result:='Unspecified Error';
  $20:Result:='Unsupported LMP Parameter Value / Unsupported LL Parameter Value';
  $21:Result:='Role Change Not Allowed';
  $22:Result:='LMP Response Timeout / LL Response Timeout';
  $23:Result:='LMP Error Transaction Collision';
  $24:Result:='LMP PDU Not Allowed';
  $25:Result:='Encryption Mode Not Acceptable';
  $26:Result:='Link Key cannot be Changed';
  $27:Result:='Requested QoS Not Supported';
  $28:Result:='Instant Passed';
  $29:Result:='Pairing With Unit Key Not Supported';
  $2A:Result:='Different Transaction Collision';
  $2B:Result:='Reserved';
  $2C:Result:='QoS Unacceptable Parameter';
  $2D:Result:='QoS Rejected';
  $2E:Result:='Channel Classification Not Supported';
  $2F:Result:='Insufficient Security';
  $30:Result:='Parameter Out Of Mandatory Range';
  $31:Result:='Reserved';
  $32:Result:='Role Switch Pending';
  $33:Result:='Reserved';
  $34:Result:='Reserved Slot Violation';
  $35:Result:='Role Switch Failed';
  $36:Result:='Extended Inquiry Response Too Large';
  $37:Result:='Secure Simple Pairing Not Supported By Host';
  $38:Result:='Host Busy - Pairing';
  $39:Result:='Connection Rejected due to No Suitable Channel Found';
  $3A:Result:='Controller Busy';
  $3B:Result:='Unacceptable Connection Parameters';
  $3C:Result:='Directed Advertising Timeout';
  $3D:Result:='Connection Terminated due to MIC Failure';
  $3E:Result:='Connection Failed to be Established';
  $3F:Result:='MAC Connection Failed';
  $40:Result:='Coarse Clock Adjustment Rejected but Will Try to Adjust Using Clock';
 end;
end;

procedure DecodeEvent(ev:array of byte);
var 
 len,num:byte;
 i:integer;
 s:string;
 // op:word;
begin
 if length(ev) < 3 then exit;
 if ev[0] <> HCI_EVENT_PKT then
  exit;
 len:=ev[2];
 num:=0;
 if len + 2 <> high(ev) then exit;
 case ev[1] of 
  // event code
  $0e:  // command complete
      begin
       num:=ev[3];          // num packets controller can accept
       //       op:=ev[5] * $100 + ev[4];
       //Log('OGF ' + inttohex(ogf(op),2) + ' OCF ' + inttohex(ocf(op),3) + ' OP Code ' + inttohex(op,4) + ' Num ' + num.ToString + ' Len ' + len.ToString);
       if (len > 3) and(ev[6] > 0) then Log('Status ' + ErrToStr(ev[6]));
      end;
  else
   begin
    s:='';
    for i:=low(ev) + 1 to high(ev) do
     s:=s + ' ' + ev[i].ToHexString(2);
    Log('Unknown event ' + s);
   end;
 end;
 if num > 0 then
  QueueEvent.SetEvent;
end;

function Monitor(Parameter:Pointer):PtrInt;
var 
 Capture1,Capture2:Integer;
begin
 Result:=0;
 while True do
  begin
   Capture1:=SerialDeviceReadEnterCount;
   Capture2:=SerialDeviceReadExitCount;
   if Capture1 <> Capture2 then
    Log(Format('SerialDeviceRead is not balanced: %d entries %d exits',[Capture1,Capture2]));
   Sleep(5*1000);
  end;
end;

function ReadExecute(Parameter:Pointer):PtrInt;
var 
 c:LongWord;
 b:byte;
 i,j,rm:integer;
 decoding:boolean;
 pkt:array of byte;
 res:LongWord;
begin
 try
  Result:=0;
  Log(Format('ReadExecute thread handle %8.8x',[ThreadGetCurrent]));
  SerialDeviceReadResetEnterExitCounts;
  // put monitoring thread on same cpu as ReadExecute to avoid cross-cpu caching issues
  ThreadSetCpu(MonitorReadExecuteHandle,CpuGetCurrent);
  ThreadYield;
  c:=0;
  while True do
   begin
    ThreadYield;
    res:=SerialDeviceRead(UART0,@b,1,SERIAL_READ_NON_BLOCK,c);
    if (res = ERROR_SUCCESS) and (c = 1) then
     begin
      // One byte was received,try to read everything that is available
      SetLength(RxBuffer,length(RxBuffer) + 1);
      RxBuffer[high(RxBuffer)]:=b;
      res:=SerialDeviceRead(UART0,@b,1,SERIAL_READ_NON_BLOCK,c);
      while (res = ERROR_SUCCESS) and(c = 1) do
       begin
        SetLength(RxBuffer,length(RxBuffer) + 1);
        RxBuffer[high(RxBuffer)]:=b;
        res:=SerialDeviceRead(UART0,@b,1,SERIAL_READ_NON_BLOCK,c);
       end;
      //if Length(RxBuffer) > 50 then
      // Log(Format('rx buffer %d',[Length(RxBuffer)]));
      i:=0;
      decoding:=True;
      while decoding do
       begin
        decoding:=False;
        if RxBuffer[i] <> HCI_EVENT_PKT then
         Log(Format('not event %d',[RxBuffer[i]]))
        else if (i + 2 <= high(RxBuffer)) then // mimumum
              if i + RxBuffer[i + 2] + 2 <= high(RxBuffer) then
               begin
                SetLength(pkt,RxBuffer[i + 2] + 3);
                for j:=0 to length(pkt) - 1 do
                 pkt[j]:=RxBuffer[i + j];
{$ifdef show_data}
                s:='';
                for j:=low(pkt) to high(pkt) do
                 s:=s + ' ' + pkt[j].ToHexString(2);
                Log('<--' + s);
{$endif}
                DecodeEvent(pkt);
                i:=i + length(pkt);
                decoding:=i < high(RxBuffer);
               end;
       end;
      // decoding
      if i > 0 then
       begin
        rm:=length(RxBuffer) - i;
        //              Log('Remaining ' + IntToStr(rm));
        if rm > 0 then
         for j:=0 to rm - 1 do
          RxBuffer[j]:=RxBuffer[j + i];
        SetLength(RxBuffer,rm);
       end;
     end;
   end;
 except
  on E:Exception do
       Log(Format('ReadExecute exception %s',[E.Message]));
end;
end;

function OpenUART0:boolean;
var 
 res:LongWord;
begin
 Result:=False;
 UART0:=SerialDeviceFindByDescription(BCM2710_UART0_DESCRIPTION);
 if UART0 = nil then
  begin
   Log('Can''t find UART0');
   exit;
  end;
 res:=SerialDeviceOpen(UART0,115200,SERIAL_DATA_8BIT,SERIAL_STOP_1BIT,SERIAL_PARITY_NONE,SERIAL_FLOW_NONE,0,0);
 if res = ERROR_SUCCESS then
  begin
   Result:=True;
   GPIOFunctionSelect(GPIO_PIN_14,GPIO_FUNCTION_IN);
   GPIOFunctionSelect(GPIO_PIN_15,GPIO_FUNCTION_IN);
   // GPIOPullSelect(GPIO_PIN_32,GPIO_PULL_NONE);                    //Added
   GPIOFunctionSelect(GPIO_PIN_32,GPIO_FUNCTION_ALT3);     // TXD0
   // GPIOPullSelect(GPIO_PIN_33,GPIO_PULL_UP);                        //Added
   GPIOFunctionSelect(GPIO_PIN_33,GPIO_FUNCTION_ALT3);     // RXD0
   ReadHandle:=BeginThread(@ReadExecute,Nil,ReadHandle,THREAD_STACK_DEFAULT_SIZE);
   Result:=ReadHandle <> INVALID_HANDLE_VALUE;
  end;
end;

procedure CloseUART0;
begin
 if ReadHandle <> INVALID_HANDLE_VALUE then KillThread(ReadHandle);
 ReadHandle:=INVALID_HANDLE_VALUE;
 if UART0 <> nil then SerialDeviceClose(UART0);
 UART0:=Nil;
end;

procedure AddHCICommand(OpCode:Word; Params:array of byte);
var 
 anItem:PQueueItem;
 i:integer;
begin
 New(anItem);
 anItem^.OpCode:=OpCode;
 SetLength(anItem^.Params,length(Params));
 for i:=0 to length(Params) - 1 do
  anItem^.Params[i]:=Params[i];
 anItem^.Next:=Nil;
 anItem^.Prev:=Last;
 if First = nil then First:=anItem;
 if Last <> nil then Last^.Next:=anItem;
 Last:=anItem;
 if MailSlotSend(Queue,Integer(anItem)) <> ERROR_SUCCESS then
  Log('Error adding Command to queue.');
end;

procedure AddHCICommand(OGF:byte; OCF:Word; Params:array of byte);
begin
 AddHCICommand((OGF shl 10) or OCF,Params);
end;

function QueueHandler(Parameter:Pointer):PtrInt;
var 
 anItem:PQueueItem;
 Cmd:array of byte;
 i:integer;
 res,count:LongWord;
 s:string;
begin
 Result:=0;
 while True do
  begin
   QueueEvent.ResetEvent;
   anItem:=PQueueItem(MailslotReceive(Queue));
   if anItem <> nil then
    begin
     Inc(HciSequenceNumber);
     //if anItem^.OpCode <> $fc4c then
     // Log(Format('started hci sequence %d op code %04.4x',[HciSequenceNumber,anItem^.OpCode]));
     if (ogf(anItem^.OpCode) = OGF_MARKER) and(ocf(anItem^.OpCode) > 0) then
      begin
       case ocf(anItem^.OpCode) of 
        DELAY_50MSEC:QueueEvent.WaitFor(50);
        DELAY_2SEC   :
                      begin
                       QueueEvent.WaitFor(2000); Log('2 seconds');
                      end;
        OPEN_PORT   :OpenUART0;
        CLOSE_PORT  :CloseUART0;
       end;
       if Assigned(@MarkerEvent) then MarkerEvent(ocf(anItem^.OpCode));
      end
     else
      begin
       SetLength(Cmd,length(anItem^.Params) + 4);
       Cmd[0]:=HCI_COMMAND_PKT;
       Cmd[1]:=lo(anItem^.OpCode);          // little endian so lowest sent first
       Cmd[2]:=hi(anItem^.OpCode);
       Cmd[3]:=length(anItem^.Params);
       for i:=0 to length(anItem^.Params) - 1 do
        Cmd[4 + i]:=anItem^.Params[i];
       count:=0;
{$ifdef show_data}
       s:='';
       for i:=0 to length(Cmd) - 1 do
        s:=s + ' ' + Cmd[i].ToHexString(2);
       Log('--> ' + s);
{$endif}
       res:=SerialDeviceWrite(UART0,@Cmd[0],length(Cmd),SERIAL_WRITE_NONE,count);
       if res = ERROR_SUCCESS then
        begin
         if QueueEvent.WaitFor(3*1000) <> wrSignaled then
          begin
           s:='';
           for i:=0 to length(Cmd) - 1 do
            s:=s + ' ' + Cmd[i].ToHexString(2);
           Log(Format('hci command sequence number %d op code %4.4x',[HciSequenceNumber,anItem^.OpCode]));
           Log(Format('-->(%d) %s',[Length(Cmd),s]));
           Log('Timeout waiting for BT Response.'); // should send nop ???
           s:='';
           for i:=0 to length(RxBuffer) - 1 do
            s:=s + ' ' + RxBuffer[i].ToHexString(2);
           Log('<-- ' + s);
           ThreadHalt(0);
          end;
        end
       else
        Log('Error writing to BT.');
      end;
     SetLength(anItem^.Params,0);
     Dispose(anItem);
    end;
  end;
end;

procedure NoOP;  // in spec but not liked by BCM chip
begin
 AddHCICommand($00,$00,[]);
end;

procedure AddMarker(Marker:Word);
begin
 AddHCICommand(OGF_MARKER,Marker and $3ff,[]);
end;

procedure ResetChip;
begin
 AddHCICommand(OGF_HOST_CONTROL,$03,[]);
end;

procedure BCMLoadFirmware(fn:string);
var 
 hdr:array [0 .. 2] of byte;
 Params:array of byte;
 i,n,len:integer;
 Op:Word;
const 
 FirmwareLoadDelays = 1;
begin
 //Log('Loading Firmware file ' + fn);
 FWHandle:=FSFileOpen(fn,fmOpenRead);
 if FWHandle > 0 then
  begin
   AddMarker(FIRMWARE_START);
   AddHCICommand(OGF_VENDOR,$2e,[]);
   n:=FSFileRead(FWHandle,hdr,3);
   while (n = 3) do
    begin
     Op:=(hdr[1] * $100) + hdr[0];
     len:=hdr[2];
     SetLength(Params,len);
     n:=FSFileRead(FWHandle,Params[0],len);
     if (len <> n) then Log('Data mismatch.');
     AddHCICommand(Op,Params);
     n:=FSFileRead(FWHandle,hdr,3);
    end;
   FSFileClose(FWHandle);
   AddMarker(FIRMWARE_END);
   AddMarker(CLOSE_PORT);
   // AddMarker(DELAY_2SEC);
   for I:=1 to FirmwareLoadDelays do
    AddMarker(DELAY_50MSEC);
   AddMarker(OPEN_PORT);
  end
 else
  Log('Error loading Firmware file ' + fn);
end;

procedure WaitForSDDrive;
begin
 while not DirectoryExists('C:\') do
  sleep(500);
end;

procedure DoMarkerEvent(no : integer);
begin
 case no of 
  FIRMWARE_START : Log('Load Firmware ...');
  FIRMWARE_END   : Log('Load Firmware done');
  SYSTEM_RESTART :
                  begin
                   Log('test was successful - delaying 3 seconds then restarting to try to obtain failure ...');
                   Sleep(3*1000);
                   RestoreBootFile('test','config.txt');
                   Log('restarting ...');
                   Sleep(1*1000);
                   SystemRestart(0);
                  end;
  //OPEN_PORT      : Log('Opening UART0.');
  //CLOSE_PORT     : Log('Closing UART0.');
  INIT_COMPLETE  :
                  begin
                   Log('BLE Chip Initialised');
                  end;
 end;
end;

procedure StartLogging;
begin
 LOGGING_INCLUDE_COUNTER:=False;
 CONSOLE_REGISTER_LOGGING:=True;
 LoggingConsoleDeviceAdd(ConsoleDeviceGetDefault);
 LoggingDeviceSetDefault(LoggingDeviceFindByType(LOGGING_TYPE_CONSOLE));
end;

begin
 Console1 := ConsoleWindowCreate(ConsoleDeviceGetDefault,CONSOLE_POSITION_LEFT,True);
 Log('Bluetooth Low Energy (BLE) Peripheral Test');
 RestoreBootFile('default','config.txt');
 StartLogging;
 SetLength(RxBuffer,0);
 Queue:=MailSlotCreate(1024);
 QueueEvent:=TEvent.Create(Nil,True,False,'');
 QueueHandle:=BeginThread(@QueueHandler,Nil,QueueHandle,THREAD_STACK_DEFAULT_SIZE);
 MonitorReadExecuteHandle:=BeginThread(@Monitor,Nil,MonitorReadExecuteHandle,THREAD_STACK_DEFAULT_SIZE);

 Log('Q - Quit - use default-config.txt');
 Log('R - Restart - use test-config.txt');
 WaitForSDDrive;


 HTTPListener:=THTTPListener.Create;
 HTTPListener.Active:=True;
 WebStatusRegister(HTTPListener,'','',True);

 MarkerEvent:=@DoMarkerEvent;          // set marker event(called when marker processed on event queue)
 AddMarker(OPEN_PORT);                 // open uart
 AddMarker(DELAY_50MSEC);              // ensure read thread has started
 ResetChip;                            // reset chip
 BCMLoadFirmware('BCM43430A1.hcd');    // load firmware
 AddMarker(INIT_COMPLETE);             // indicate initialisation complete
 AddMarker(SYSTEM_RESTART);

 while True do
  begin
   if ConsoleGetKey(ch,nil) then
    case uppercase(ch) of 
     'Q' : SystemRestart(0);
     'R' :
          begin
           RestoreBootFile('test','config.txt');
           SystemRestart(0);
          end;
     'C' : ConsoleWindowClear(Console1);
    end;
   ThreadHalt(0);
  end;
end.
