/*
   import_gtfs_bus_routes_2.sas
   authors: cheither & npeterson
   revised: 5/21/13
   ----------------------------------------------------------------------------
   Program is called by import_gtfs_bus_routes.py and formats bus itineraries
   to build with arcpy.

   Hardcoded inputs (after filename section):
   1. Pseudo nodes - Inserted into routes to force passage through specific
      nodes; generally used to correct express bus coding that is routed
      incorrectly when left to its own devices. Review before importing routes
      after major network edits.
   2. Pace zone fares - Listing of Pace Premium service with a surcharge even
      for pass-holders. Review when GTFS updates are imported.

   Processing steps:
    1. Import header and itinerary files.
       - Identify & remove routes with only one itinerary segment where
         ITIN_A = ITIN_B.
       - Only keep coding for routes with corresponding itinerary coding.
       - Create variables (TRANSIT_LINE, MODE, TYPE, DESCRIPTION, ETC.) to
         store coding.
    2. Make adjustments if necessary.
       - Adjust itinerary coding if segment has same node at beginning and end.
       - Insert pseudo nodes into itinerary.
       - Apportion line times over Pace segments with duplicate times & attach
         Pace zone fare.
       - Adjust itinerary coding if it contains nodes not available in the
         network (if the initial processing network is out of sync with the
         current MHN).
       - Iterate through list of itinerary gaps to find shortest path.
           * write_dictionary.sas - Creates a Python dictionary of MHN links
             and their length. The node coordinates of the itinerary segment
             being analyzed are used to make a bounding box to limit the MHN
             links processed.
           * shortest_path.py - A Python script that finds the shortest path
             between the nodes identifying the itinerary gap. This script uses
             brute force so limiting the MHN being analyzed greatly increased
             the efficiency.
           * read_path_output.sas - Inserts the shortest path information into
             the itineraries and recalculates values.
       - Calculate the AM Peak share of the route.

*/
options noxwait;

%let maxzn=1961;     ** highest zone09 POE;
%let peakst=25200;   ** 7:00 AM in seconds;
%let peakend=32400;  ** 9:00 AM in seconds;
%let search=5280;    ** search distance for shortest path file;

** -- FIXED VARIABLES -- **;
%let inpath=%scan(&sysparm,1,$);
%let dir=%scan(&sysparm,2,$);
%let hdr=%scan(&sysparm,3,$);
%let itn=%scan(&sysparm,4,$);
%let counter=%scan(&sysparm,5,$);
%let count=1;
%let tothold=0;
%let samenode=0;
%let badnode=0;
%let totfix=0;
%let xmin=0; %let xmax=0; %let ymin=0; %let ymax=0;
%let pnd=0;
%let patherr=0;
%let flag32=0;      *** flag for Python3.2;
%let timefix=0;

/*_____________________________________________________________*/
                   * INPUT FILES *;
filename in1 "&inpath.&hdr..csv";
filename in2 "&inpath.&itn..csv";
filename in3 "&dir.output\mhnlinks.txt";
filename in4 "&dir.import\short_path.txt";
filename in5 "&dir.output\mhnnodes.txt";
filename in6 "&dir.output\mhnsec.txt";

                   * OUTPUT FILES *;
filename out1 "&dir.import\itin.txt";
filename out2 "&dir.import\path.txt";
filename out3 "&dir.import\route.txt";
filename out4 "&dir.import\link_dictionary.txt";
filename out5 "&dir.import\ab.txt";
/*_____________________________________________________________*/

*=======================================================================*;
 *** LIST PSEUDO-NODES USED TO LOCATE ROUTE CORRECTLY ***;
   * - these are inserted into routes to force them to pass through specific nodes -;
   * - pnode1 & 2 are forced locations, newlink is number of segments inserted (number of pnodes +1) -;
   * - each entry represents 1 direction only -;
*=======================================================================*;
data pseudo; infile datalines missover dsd;
  input mode $1. route_id $ itinerary_a itinerary_b pnode1 pnode2 newlink;
  datalines;
   E,33,15184,15886,21263,,2
   E,33,15886,15184,21263,,2
   E,33,14844,15886,15184,21263,3
   E,33,15886,14844,21263,15184,3
   E,146,15886,15418,15485,,2
   E,145,15886,15418,15485,,2
   E,134,15514,20903,21258,20898,3
   E,134,20897,15514,16092,21257,3
   E,143,15886,15514,21257,,2
   E,143,15514,15886,21258,,2
   E,135,20897,15418,15485,,2
   E,136,15215,20900,20896,,2
   E,136,20897,15215,16092,20054,3
   E,148,15886,15215,20054,,2
   E,2,15992,16279,21317,,2
   E,2,16258,15992,21310,,2
   E,2,16279,15992,21312,,2
   Q,600,9873,12187,10037,11730,3
   Q,672,7924,8123,8121,,2
   Q,888,15589,11313,11475,,2
   P,392,13501,12120,13468,12840,3
   P,395,13113,11804,12997,11832,3
   P,626,13528,11381,13462,11970,3
   P,890,14746,11804,11832,,2
   P,892,16898,11804,16894,11832,3
   Q,895,13323,12187,11459,21662,3
   Q,895,13323,9842,11459,,2
   Q,895,12187,13323,11437,11440,3
   Q,895,9842,13323,11440,,2
   ;
    proc sort; by mode route_id;


*=======================================================================*;
 *** PACE ZONE FARES LIST ***;
   * - from Pace Year 2011 fare sheet on pacebus.com -;
   * - Premium service has a $2.25 surcharge even for pass-holders -;
*=======================================================================*;
data pacezf; infile datalines missover dsd;
  input mode $1. route_id $ zonefr;
  datalines;
   Q,237,225
   Q,282,225
   Q,284,225
   Q,755,225
   Q,768,225
   Q,769,225
   Q,773,225
   Q,774,225
   Q,775,225
   Q,776,225
   Q,779,225
   Q,855,225
   ;
    proc sort; by mode route_id;
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *;



%macro getdata;
  %if %sysfunc(fexist(in1)) %then %do;
        ** READ IN BUS CODING **;
       proc import out=route datafile="&inpath.&hdr..csv" dbms=csv replace; getnames=yes; guessingrows=10000;
       data route(drop=route_id); set route; length temp_id $8.; temp_id=route_id;
       data route(rename=(temp_id=route_id)); set route; proc sort; by line;
  %end;
  %else %do; data null; file "google_buspath2.lst"; put "File not found: &inpath.&hdr..csv"; %end;

  %if %sysfunc(fexist(in2)) %then %do;
       proc import out=sec1 datafile="&inpath.&itn..csv" dbms=csv replace; getnames=yes; guessingrows=10000;
       proc sort data=sec1; by line;
  %end;
  %else %do; data null; file "google_buspath2.lst" mod; put "File not found: &inpath.&itn..csv"; %end;
%mend getdata;
%getdata
run;


 *** IDENTIFY & REMOVE ROUTES WITH ONLY ONE ITINERARY SEGMENT WHERE ITINA=ITINB AND BAD DATA ***;
data sec1; set sec1(where=(line is not null & itinerary_a is not null & itinerary_b is not null));               ** drop garbage;
data check; set sec1; proc summary nway; class line; output out=chk1;
data sec1; merge sec1 chk1; by line;
data sec1(drop=_type_ _freq_) bad; set sec1;
  if _freq_=1 & itinerary_a=itinerary_b then output bad; else output sec1;

data bad; set bad; proc print; title "Bad Itinerary Coding";


data keeprte(keep=line); set sec1; proc sort nodupkey; by line;
data route; merge route keeprte (in=hit); by line; if hit;


 *** PROCESS ROUTES FOR ARC PATH BUILDING ***;
data route(drop=shape_id); set route;
  if line='' then delete;               ** drop blank rows in spreadsheet;
  description=upcase(compress(description,"'")); route_long_name=upcase(compress(route_long_name,"'"));
  direction=upcase(compress(direction,"'")); terminal=upcase(compress(terminal,"'"));
  speed=round(max(speed,15));

 /* beginning 07-11-2012: addressed in MAS procedures
  if index(route_long_name,'EXPRESS')>0 and mode='B' then mode='E';
  if ( index(route_long_name,'SHUTTLE')>0 or index(route_long_name,'FEEDER')>0 or index(route_long_name,'LOCAL')>0
      or index(route_long_name,'CIRCULATOR')>0 ) and mode='P' then mode='L';
 */

  if mode='B' then type=1; else if mode='E' then type=2; else if mode='P' then type=3;
  else if mode='Q' then type=4; else if mode='L' then type=5;
    proc sort; by mode line;

data route; set route; by mode line; ty=lag(type);
data route; set route; by mode line;
  retain q &counter;
  q+1;
  if type ne ty then q=&counter+1;
  output;

data route(drop=q ty); set route;
 length newline $6. temp1 $5. descr $50.;
  temp1=q; temp2=_n_;
  newline=tranwrd(lowcase(mode)||temp1,'','0');
  descr=trim(route_id)||" "||trim(route_long_name)||": "||trim(direction)||" TO "||trim(terminal);
   proc sort; by newline;

data route; set route;
  batch=int(temp2/100)+1;                                    ** setup in groups of 99 for AML processing**;

data rte1(drop=description type batch temp1 temp2);
  retain line route_id route_long_name direction terminal descr mode speed newline; set route;
proc export data=rte1 outfile="&inpath.routes_processed.csv" dbms=csv replace;


proc sql noprint;
  create table section as
      select sec1.*,
	       route.newline, batch
      from sec1,route
      where sec1.line=route.line;


data section(drop=shape_id shape_dist_trav_a shape_dist_trav_b); set section;
  if order ne int(order) then delete;   ** drop skeleton link coding accidentally left in;
  zfare=max(zfare,0);
  ttf=max(ttf,0);
  ltime=round(max(ltime,0),.1);
  imputed=0;
  link_stops=max(link_stops,0);
  group=lag(line);
  rename skip_flag=dwcode;
   proc sort; by newline order;

data x; set section(where=(itinerary_a is null or itinerary_b is null )); proc print; title "Check1";

 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;
       ** -- Adjust Itinerary Coding if Segment has Same Node at Beginning and Ending, If Necessary -- **;

data same section; set section;
  if itinerary_a=itinerary_b then output same; else output section;

data temp; set same nobs=smnode; call symput('samenode',left(put(smnode,8.))); run;

%macro segfix;
  %if &samenode>0 %then %do;

      proc sort data=same; by newline order;
      data same; set same; by newline order;
         nl=lag(newline); o=lag(order);
      data same; set same;
        retain g 0;
         if newline ne nl and order ne o+1 then g+1;
          output;

       proc summary nway; class g newline; var order dep_time arr_time ltime link_stops;
          output out=fixit max(order)=ordmax min(order)=ordmin min(dep_time)= max(arr_time)= sum(ltime)=addtime sum(link_stops)=addstop;
       proc summary nway data=section; class newline; var order; output out=lineend max=lnmax;
       data fixit(drop=_type_ _freq_); merge fixit lineend; by newline;
       data fix1(keep=newline order arr_time addtime addstop); set fixit(where=(ordmax>lnmax));       *** adjust data if last entry in itinerary;
          order=ordmin-1;
       data fix2(keep=newline order dep_time addtime2 addstop2); set fixit(where=(ordmax<=lnmax));    *** apply to subsequent segment;
          order=ordmax+1; rename addtime=addtime2 addstop=addstop2;

       data section(drop=addtime addstop addtime2 addstop2); merge section (in=hit) fix1 fix2; by newline order; if hit;
         if addtime>0 or addtime2>0 then do;
           addtime=max(addtime,0); addtime2=max(addtime2,0); ltime=ltime+addtime+addtime2;
           addstop=max(addstop,0); addstop2=max(addstop2,0); link_stops=link_stops+addstop+addstop2;
         end;

  %end;
%mend segfix;
%segfix
 /* end macro*/
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;

data x; set section(where=(itinerary_a is null or itinerary_b is null )); proc print; title "Check2";
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;
       ** -- Insert Pseudo Nodes into Itinerary, If Necessary -- **;
proc sql noprint;
 create table check as
     select route.newline,
            pseudo.itinerary_a, itinerary_b, pnode1, pnode2, newlink
     from route, pseudo
     where route.mode=pseudo.mode & route.route_id=pseudo.route_id
     order by newline,itinerary_a,itinerary_b;

data temp; set check nobs=pndfix; call symput('pnd',left(put(pndfix,8.))); run;

%macro fixpseudo;
  %if &pnd>0 %then %do;

    proc sort data=section; by newline itinerary_a itinerary_b;
    data pfix; merge section(in=hit) check; by newline itinerary_a itinerary_b; if hit;
    data pfix section; set pfix; if pnode1>0 then output pfix; else output section;
    data pfix; set pfix; n=1; output; n=2; output; if newlink=3 then do; n=3; output; end;
    data pfix; set pfix;
      ltime=round(ltime/newlink,0.1); order=n/10+order; tm=round((arr_time-dep_time)/newlink);
      if newlink=2 then do;
         if n=1 then do; itinerary_b=pnode1; dwcode=1; arr_time=dep_time+tm; end;
         else do; itinerary_a=pnode1; dep_time=dep_time+tm; end;
      end;
      if newlink=3 then do;
         if n=1 then do; itinerary_b=pnode1; dwcode=1; arr_time=dep_time+tm; end;
         else if n=2 then do; itinerary_a=pnode1; itinerary_b=pnode2; dwcode=1; dep_time=dep_time+tm; arr_time=dep_time+tm; end;
         else do; itinerary_a=pnode2; dep_time=dep_time+(tm*2); end;
      end;

    data dwadj(keep=newline newb pnode1); set pfix(where=(itinerary_b=pnode1 or itinerary_b=pnode2)); rename itinerary_b=newb;
    data section(drop=pnode1 pnode2 newlink n tm); set section pfix;
      proc sort; by newline order;
     run;
  %end;
%mend fixpseudo;
%fixpseudo
 /* end macro*/
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;

data x; set section(where=(itinerary_a is null or itinerary_b is null )); proc print; title "Check3";
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;
       ** -- Apportion Line Times Over Pace Segments & Attach Pace Zone Fare -- **;
data qroute; set route(where=(mode='Q')); proc sort; by mode route_id;
data qroute(keep=newline zonefr); merge qroute(in=hit1) pacezf(in=hit2); by mode route_id; if hit1 & hit2; proc sort; by newline;

data cta pace; set section;
  if substr(newline,1,1)='b' or substr(newline,1,1)='e' then output cta; else output pace;

data pace(drop=zonefr); merge pace(in=hit) qroute; by newline; if hit;
  if zonefr>0 & order=1 then zfare=zonefr;
  dt=lag(dep_time);
  proc sort; by newline order;

** Estimate Times for Pace Lines where first dep_time=last arr_time **;
data first(keep=newline dep_time); set pace; by newline order; if first.newline;
data last(keep=newline arr_time); set pace; by newline order; if last.newline;
data chk; merge first last; by newline; if dep_time=arr_time;
data _null_; set chk nobs=tmfix; call symput('timefix',left(put(tmfix,8.))); run;

%macro sametime;
  %if &timefix>0 %then %do;

     data chk(keep=newline flag); set chk; flag=1;
     data pace; merge pace chk; by newline;
     data timefix; set pace(where=(flag=1));

         ** Use Node Coordinates, 30 MPH & Euclidean distance to estimate new final arrival time ... **;
     data node; infile in5 missover dlm=',';
        input itinerary_a ax ay;  proc sort; by itinerary_a;
     data nodeb; set node; rename itinerary_a=itinerary_b ax=bx ay=by; proc sort; by itinerary_b;

     proc sort data=timefix; by itinerary_a;
     data timefix; merge timefix(in=hit) node; by itinerary_a; if hit; proc sort; by itinerary_b;
     data timefix; merge timefix(in=hit) nodeb; by itinerary_b; if hit;
        dist=sqrt((ax-bx)**2+(ay-by)**2)/5280;
        minutes=round(dist/30*60,0.1);

     proc summary nway data=timefix; class newline; var order minutes; output out=fixed max(order)= sum(minutes)=totmin;
     data timefix(keep=newline order minutes); set timefix;  proc sort; by newline order;

         ** ... And Calculate New Estimated Ltime **;
     proc sort data=pace; by newline order;
     data pace(drop=_type_ _freq_ flag minutes totmin); merge pace timefix fixed; by newline order;
        if minutes then ltime=minutes;
        if totmin then arr_time=round(totmin*60+arr_time);
     run;

  %end;
%mend sametime;
%sametime
 /* end macro*/


data pace; set pace;
   retain grupo 0;
     if line ne group or dep_time ne dt then grupo+1; output;
  proc sort; by itinerary_a;

** Attach Node Coordinates to Calculate Distance **;
data node; infile in5 missover dlm=',';
  input itinerary_a ax ay;  proc sort; by itinerary_a;
data nodeb; set node; rename itinerary_a=itinerary_b ax=bx ay=by; proc sort; by itinerary_b;
data pace; merge pace(in=hit) node; by itinerary_a; if hit; proc sort; by itinerary_b;
data pace(drop=dt ax ay bx by); merge pace(in=hit) nodeb; by itinerary_b; if hit;
 dist=sqrt((ax-bx)**2+(ay-by)**2)/5280;
  proc sort; by newline order grupo;
proc summary nway data=pace; class grupo; var dist ltime; output out=fixpace sum(dist)=miles sum(ltime)=time n=elements;
data pace(drop=_type_ _freq_ dist miles grupo time); merge pace fixpace; by grupo;
  if elements>1 then do;          ** only adjust the segments that need it **;
     ltime=round(dist/miles*time,0.1);
     if ltime>0 then arr_time=(ltime*60)+dep_time;
     if ltime=. then ltime=time;
  end;
  proc sort; by newline order;

proc summary nway data=pace; class newline; var dep_time; output out=st min=strtln;

data pace(drop=_type_ _freq_); merge pace st; by newline;
  retain all 0;
   if first.newline then all=0;
   output;
   all=all+ltime;

data pace(drop=strtln all elements); set pace; by newline order;
  if elements>1 then do;
     if first.newline then arr_time=(ltime*60)+strtln;
     else do; dep_time=(all*60)+strtln; arr_time=(ltime+all)*60+strtln; end;
  end;

data section; set cta pace; proc sort; by newline order;
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;
data x; set section(where=(itinerary_a is null or itinerary_b is null )); proc print; title "Check4";

data verify; set section; proc sort; by itinerary_a itinerary_b;


          *-----------------------------------*;
                   ** VERIFY CODING **;
          *-----------------------------------*;
** Read in MHN Links **;
data m; infile in3 missover dlm=',';
  input link itinerary_a itinerary_b dir mhnmi typ1 typ2 spd1 spd2 base;
     proc sort; by link;

data sec; infile in6 missover dlm=',';
  input link action spd1 spd2 dir;
   if action=3 then action=5;                                        *** make delete largest action value;
     proc summary nway; class link; var action spd1 spd2 dir; output out=sec2 max=;
data sec2(drop=_type_ _freq_); set sec2;
  if spd1=0 then spd1=.; if spd2=0 then spd2=.; if dir=0 then dir=.; base=1;

data trueab(drop=action); update m sec2; by link;
  if action=5 or typ1=6 then delete;

data mhn(drop=c spd2 typ2 link); set trueab(where=(base=1));
    match=1;
     output;
    if dir>1 then do;
      c=itinerary_a; itinerary_a=itinerary_b; itinerary_b=c; typ1=max(typ1,typ2); spd1=max(spd1,spd2);
      output;
    end;
  proc sort; by itinerary_a itinerary_b;


** Read in MHN Nodes **;
data node; infile in5 missover dlm=',';
  input itinerary_a ax ay;  proc sort; by itinerary_a;
data ntwk; merge mhn (in=hit) node; by itinerary_a; if hit;


data nodechk(keep=itinerary_a); set section;
  output; itinerary_a=itinerary_b; output;
    proc sort nodupkey; by itinerary_a;
data nd; set ntwk;
  output; itinerary_a=itinerary_b; output;
    proc sort nodupkey; by itinerary_a;


 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;
       ** -- Adjust Itinerary Coding if it Contains Nodes not Available in the Network, If Necessary -- **;

data nodechk(keep=itinerary_a); merge nodechk nd (in=hit); by itinerary_a; if hit then delete;
  proc print; title "Itinerary Nodes Not in the Network";
data temp; set nodechk nobs=nonode; call symput('badnode',left(put(nonode,8.))); run;

%macro nodefix;
  %if &badnode>0 %then %do;

      data nodechk; set nodechk; fixa=1;
      data nodechk2(rename=(itinerary_a=itinerary_b fixa=fixb)); set nodechk;

      data verify; merge verify nodechk; by itinerary_a; proc sort; by itinerary_b;
      data verify; merge verify nodechk2; by itinerary_b;
      data fix verify(drop=fixa fixb); set verify;
        if fixa=1 or fixb=1 then output fix; else output verify;

      proc sort data=fix; by newline order;
      data fix; set fix; nl=lag(newline); o=lag(order);
      data fix(drop=nl o fixa fixb); set fix; by newline order;
        retain grp 0;
        if (newline ne nl) or (order ne o+1) then grp+1;
        output;
         proc sort; by grp order;

      data pt1(keep=grp line itinerary_a dep_time order newline batch group) pt2(keep=grp itinerary_b arr_time); set fix; by grp;
        if first.grp then output pt1;
        if last.grp then output pt2;

      proc summary nway data=fix; class grp; var ltime dwcode link_stops zfare ttf imputed;
        output out=pt3 sum(ltime)= max(dwcode)= sum(link_stops)= max(zfare)= max(ttf)= max(imputed)=;
      data pt(drop=_type_ _freq_ grp); merge pt1 pt2 pt3; by grp;
      data verify; set verify pt; proc sort; by itinerary_a itinerary_b;
  %end;
%mend nodefix;
%nodefix
 /* end macro*/
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;


** Find Itinerary Segements that Do Not Correspond to MHN Links **;
data verify; merge verify (in=hit) mhn; by itinerary_a itinerary_b; if hit;


** Hold Segments that Do Not Match MHN Links or are the Wrong Direction **;
** -- This file can be used for troubleshooting and verification -- **;
data hold(drop=group batch dir match); set verify(where=(match ne 1));
  proc export data=hold outfile="&dir.import\hold_times.csv" dbms=csv replace;

data temp; set hold nobs=totobs; call symput('tothold',left(put(totobs,8.))); run;


 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;
       ** -- Iterate Through List of Itinerary Gaps to Find Shortest Path, If Necessary -- **;
%macro itinfix;
  %if &tothold>0 %then %do;

      data short(keep=itinerary_a itinerary_b); set hold; proc sort nodupkey; by itinerary_a itinerary_b;
         ** -- This file can be used for troubleshooting and verification with short_path.txt -- **;
         proc export data=short outfile="&dir.import\hold_check.csv" dbms=csv replace;
      data short; set short; num=_n_;
      data temp; set short nobs=fixobs; call symput('totfix',left(put(fixobs,8.))); run;
      data _null_;
         command="if exist pypath.txt (del pypath.txt /Q)" ; call system(command);
         command="ftype Python.File >> pypath.txt" ; call system(command);

      data null; infile "pypath.txt" length=reclen;
         input location $varying254. reclen;
         loc=scan(location,2,'='); goodloc=substr(loc,1,index(loc,'.exe"')+4); flag=index(goodloc,'Python32');
         call symput('runpython',trim(goodloc)); ****call symput('flag32',left(put(flag,5.)));
         run;

      data _null_; command="if exist pypath.txt (del pypath.txt /Q)" ; call system(command);

      ** -- RUN PYTHON SCRIPT -- **;
      %do %while (&count le &totfix);
          data shrt; set short(where=(num=&count));
             call symput('a',left(put(itinerary_a,5.))); call symput('b',left(put(itinerary_b,5.))); run;


          data node1; set node(where=(itinerary_a=&a or itinerary_a=&b));
            proc summary nway data=node1; var ax ay; output out=coord min(ax)=axmin max(ax)=axmax min(ay)=aymin max(ay)=aymax;
          data coord; set coord;
             d=round(sqrt((axmax-axmin)**2+(aymax-aymin)**2),0.5); d=max(d/&search,3); d=min(d,3);   ** link coord search multiplier parameter capped at 5 miles;
             x1=axmin-(d*&search); x2=axmax+(d*&search); y1=aymin-(d*&search); y2=aymax+(d*&search);

          data _null_; set coord;
              call symput('xmin',left(put(x1,8.))); call symput('xmax',left(put(x2,8.)));
              call symput('ymin',left(put(y1,8.))); call symput('ymax',left(put(y2,8.))); run;

          data net1; set ntwk(where=(&xmin<=ax<=&xmax & &ymin<=ay<=&ymax));


          %include "&dir.Programs\Transit_feed\write_dictionary.sas";

          data _null_;
            %if &flag32>0 %then %do; %let runpython="C:\Python26\ArcGIS10.0\python.exe"; %end;
            command="%bquote(&runpython) &dir.Programs\Transit_feed\find_shortest_path.py &a &b &dir";
            call system(command); run;
%put here! flag32=&flag32 &runpython;
         %let count=%eval(&count+1);
      %end;

      ** -- READ SHORTEST PATHS FOUND -- **;
          * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *;
            ** Do a First Pass to Check for Paths not Found **;
             data nopath; infile in4 dlm="(,)";
              input length node $; if length=0;

              data _null_; set nopath nobs=totobs; call symput('patherr',left(put(totobs,8.))); run;
              %if &patherr>0 %then %do;
                 proc printto print="path_errors.txt";
                 proc print noobs data=nopath; title "***** SHORTEST PATH ERROR: NO PATH FOUND, REVIEW CODING *****";
                 proc printto;
              %end;
            ******** Add logic to verify number of entries in short_path is equal to &totfix, else stop scripts ********;
          * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *;


      %include "&dir.Programs\Transit_feed\read_path_output.sas";

  %end;
%mend itinfix;
%itinfix
 /* end macro*/
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;

 *** ADJUST QUESTIONABLE LINE TIMES ***;
data newitin; set newitin;
  group=lag(line);
  if spd1=0 then do; if typ1=2 or typ1=4 then spd1=55; else spd1=30; end;
  ltime=max(ltime,0.1);

 **************** if ltime<=0 then ltime=max(round(mhnmi/spd1*60,.1),0.1);
 ** adjust unrealistic travel times from feed data (if less than half of posted speed or more than double) **;
 **** if (mhnmi/ltime*60)<(spd1*.5) or (mhnmi/ltime*60)>(spd1*2) then ltime=max(round(mhnmi/spd1*60,.1),0.1);
 **************** if (mhnmi/ltime*60)>(spd1*2) then ltime=max(round(mhnmi/spd1*60,.1),0.1);

data check; set newitin(where=(ltime=0)); proc print; title "BAD LINE TIMES";

 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *;
** Ensure Transit Not Coded on Centroid Links **;
data bad; set newitin(where=(itinerary_a le &maxzn or itinerary_b le &maxzn));
     proc print; var itinerary_a itinerary_b line order; title 'TRANSIT CODING ON CENTROID CONNECTORS';
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *;

          *-----------------------------------*;
              ** FORMAT ITINERARY DATASET **;
          *-----------------------------------*;
data section(drop=order); set newitin;
   retain ordnew 1;
      ordnew+1;
      if line ne group then ordnew=1;
     output;
   proc sort; by newline ordnew;

 *** CALCULATE AM SHARE ***;
data section; set section; by newline ordnew;
  if dep_time>=&peakst and arr_time<=&peakend then am=1;                      ** segment occurs during AM Peak;

proc summary nway data=section; class newline; var am; output out=stats sum=;

** Get Run Start Time - Assume Zero is Incorrect **;
data sect1; set section; by newline ordnew;;
 if dep_time=0 then start=arr_time; else start=min(dep_time,arr_time);
 if start=0 then delete;
data sect1(keep=newline start); set sect1; by newline ordnew; if first.newline;

data stats(keep=newline ampct); set stats; ampct=max(0,round(am/_freq_,.01));
proc sort data=route; by newline;
data route; merge route sect1 stats; by newline; if start=. then start=0;
 strthour=int(start/3600);
  ** set headways to time period length **;
  if strthour>=20 or strthour<6 then headway=600;   ** overnight;
  else if strthour in (6,9) then headway=60;        ** AM peak shoulders;
  else if 10<=strthour<=13 then headway=240;        ** midday;
  else headway=120;


    ** Replace Route Header File for ARC **;
data rte; set route;
 length rln trmnl $32.;
  rln=substr(route_long_name,1,32); trmnl=substr(terminal,1,32);
   file out3 dsd;
     put newline descr ~ mode type headway speed temp2 batch line route_id rln ~ direction trmnl ~ start strthour ampct vehicle;


 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *;
**REPORT ITINERARY GAPS**;
data check; set section;
  z=lag(itinerary_b);
  if itinerary_a ne z and ordnew>1 then output;
   proc print; var line ordnew itinerary_a itinerary_b z; title 'Itinerary Gaps';
 * - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - *;

 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;
       ** -- Logic to Refine Paths by Condensing Excessive Doubling Back in Itineraries.                             -- **;
       **    For example: a bus traveling around Woodfield Mall may keep fluctuating between selecting nodes A & B      **;
       **    as the closest to the actual stop locations, thereby causing multiple successive instances of traveling    **;
       **    back and forth over the same roadway segemnt before continuing on.                                         **;

  *** Identify Multiple Instances of Same Segment within Routes ***;
proc summary nway data=section; class newline itinerary_a itinerary_b; output out=chk2;
data chk2(keep=newline fix); set chk2(where=(_freq_>1)); fix=1;
  proc sort nodupkey; by newline;

data part1 part2a; merge section chk2; by newline;
  if fix then output part1; else output part2a;           *** part2a is OK;

proc sort data=part1; by newline ordnew;
data part1(drop=fix); set part1; ln=lag(newline); ita=lag(itinerary_a); itb=lag(itinerary_b);
data part1; set part1;
  retain grp 0;
   if (newline ne ln) or (itinerary_a ne itb) or (itinerary_b ne ita) then grp+1;   *** flag sets of back-and-forth action;
   output;

proc summary nway data=part1; class newline grp; output out=chk3;
data chk3(keep=newline fix); set chk3(where=(_freq_>1)); fix=1; proc sort nodupkey; by newline;

data part1 part2b; merge part1 chk3; by newline;
  if fix then output part1; else output part2b;           *** part2b is OK;

data part1(drop=fix); set part1;
  retain member 0;
  member+1;
  if (newline ne ln) or (itinerary_a ne itb) or (itinerary_b ne ita) then member=1; *** determine how many times back-and-forth action is present;
  output;

data odd; set part1(where=(mod(member,2)>0 & member>1));     *** find set of segments that may be combined - must end in odd member number;
 proc summary nway; class grp; var member; output out=chk4 max=maxmem;
data chk4(keep=grp maxmem); set chk4;
data part1; merge part1 chk4; by grp;
  if member>maxmem then maxmem=.;

data fix part1; set part1;
 if maxmem then output fix; else output part1;

    *** Collapse Segments ***;
proc sort data=fix; by newline grp ordnew;
data a(keep=newline itinerary_a itinerary_b ordnew batch grp line group); set fix; by newline grp ordnew;
  if first.grp;

proc summary nway data=fix; class newline grp;
  var dwcode zfare ttf dep_time arr_time link_stops; output out=fixed max(dwcode)=
   sum(zfare)= max(ttf)= min(dep_time)= max(arr_time)= sum(link_stops)=;

data fixed(drop=_type_ _freq_); merge a fixed; by newline grp;
   ltime=round(abs(arr_time-dep_time)/60,0.1); link_stops=link_stops+_freq_; imputed=2;

data section(drop=fix ln ita itb grp member maxmem); set part1 fixed part2a part2b;
  proc sort; by newline ordnew;

data section(drop=ordnew); set section;
   retain order 1;
      order+1;
      if line ne group then order=1;
     output;
   proc sort; by newline order;
 *~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*;

data section; set section;
   retain route 0;
     if line ne group then route+1;
     output;

data section; set section;
   place=_n_;
     proc sort; by itinerary_a itinerary_b;

data arcs; infile in3 missover dlm=",";
   input itinerary_a itinerary_b;
     true=1;
      proc sort; by itinerary_a itinerary_b;

  ** Find True Arc Direction in MHN **;
data section; merge section (in=hit) arcs; by itinerary_a itinerary_b;
   if hit;
    if true=1 then abnode=itinerary_a*100000+itinerary_b;
    else abnode=itinerary_b*100000+itinerary_a;
      proc sort; by newline order;

data section; set section; by newline order;
  if last.newline then layover=3; else layover=0;

     *---------------------------------*;
        ** WRITE ITINERARY FILE **
     *---------------------------------*;
data writeout; set section;
  file out1 dlm=',';
    put newline itinerary_a itinerary_b layover dwcode zfare ltime ttf
             order route place abnode batch dep_time arr_time link_stops imputed;


     *---------------------------------------*;
      ** FORMAT PATH-BUILDING FILE FOR ARC **
     *---------------------------------------*;
data path(keep=node route batch); set section; by newline order;
   node=itinerary_a; output;
   if last.newline then do;
     node=itinerary_b; output;
   end;

data path; set path;
 rank=_n_;

     *---------------------------------*;
        ** WRITE PATH FILE **
     *---------------------------------*;
data write2; set path;
  file out2 dsd;
    put node rank route batch;


     *---------------------------------*;
      ** WRITE FILE OF ALLOWABLE LINKS **
     *---------------------------------*;
data trueab(keep=itinerary_a itinerary_b d1); set trueab; d1=1; proc sort; by itinerary_a itinerary_b;
data seg(keep=itinerary_a itinerary_b); set section; proc sort nodupkey; by itinerary_a itinerary_b;
data seg; merge seg (in=hit) trueab; by itinerary_a itinerary_b; if hit;
data seg1 seg; set seg; if d1=1 then output seg1; else output seg;
data seg(drop=c d1); set seg; c=itinerary_a; itinerary_a=itinerary_b; itinerary_b=c; proc sort; by itinerary_a itinerary_b;
data trueab(rename=(d1=d2)); set trueab;
data seg; merge seg (in=hit) trueab; by itinerary_a itinerary_b; if hit;
data seg1; merge seg1 seg; by itinerary_a itinerary_b;
  ab=itinerary_a*100000+itinerary_b; d1=max(d1,0); d2=max(d2,0);

data write2; set seg1;
  file out5 dlm=',';
    put ab d1 d2;

run;