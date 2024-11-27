
("Available output devices:"); ServerOptions.outDevices.collect({|msg| msg.postln}); "";

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                     START MAIN CODE                                                        //
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
(
////////////////////////////////
//1. server config
////////////////////////////////

s = Server.local;
s.options.outDevice_(
	// "Windows WASAPI : Speaker/HP (Realtek High Definition Audio)"
	// "ASIO : ReaRoute ASIO (x64)"
	// "ASIO : Focusrite USB ASIO"
	"ASIO : AudioBox ASIO Driver"
);
s.options.numOutputBusChannels_(2);

s.options.sampleRate_(48000);

s.options.memSize_(2.pow(20));
s.newBusAllocators; // resets the bus allocation counter
// ServerBoot.removeAll; // causes a problem with FreqScope
ServerTree.removeAll;
ServerQuit.removeAll;

// clean up
// s.freeAll;
Buffer.freeAll;
OSCdef.freeAll;
Window.closeAll;

////////////////////////////////
//2. initialize global variables
////////////////////////////////

// T-Stick name
~tStick = "TStick_514";

// receiving port
~recvPort = 8000;

// audio output bus
~out = 0;

// Audio folder (folder must at the same level as the scd file)
~audio = "audio";

// List of DMI control parameters [OSC address, size, mapped or not]
~tStickParam = [
	["/raw/capsense"                 ,      30,         ],
	["/raw/fsr"                      ,       1, "mapped"],
	["/raw/accl"                     ,       3, "mapped"],
	["/raw/gyro"                     ,       3, "mapped"],
	["/raw/magn"                     ,       3,         ],
	["/instrument/shakexyz"          ,       3, "mapped"],
	["/instrument/squeeze"           ,       1,         ],
	["/instrument/touch/all"         ,       1, "mapped"],
	["/instrument/touch/top"         ,       1,         ],
	["/instrument/touch/middle"      ,       1,         ],
	["/instrument/touch/bottom"      ,       1,         ],
	["/instrument/touch/discrete"    ,      30, "mapped"],
	["/instrument/jabxyz"            ,       3,         ],
	["/instrument/brush"             ,       1,         ],
	["/instrument/multibrush"        ,       4,         ],
	["/instrument/rub"               ,       1,         ],
	["/instrument/multirub"          ,       4,         ],
	["/instrument/button/count"      ,       1,         ],
	["/instrument/button/tap"        ,       1,         ],
	["/instrument/button/ttap"       ,       1,         ],
	["/battery/percentage"           ,       1,         ],
	["/battery/current"              ,       1,         ],
	["/battery/timetoempty"          ,       1,         ],
	["/battery/voltage"              ,       1,         ],
	["/orientation"                  ,       4,         ],
	["/ypr"                          ,       3,         ]
];

// List of sound synthesis control parameters [, [intial values], mapped or not]
~granParam = [
	["sndBuf"        ,                   [ 0 ],         ],
	["dens"          ,                  [ 10 ], "mapped"],
	["sync"          ,                [ 0.75 ],         ],
	["gDur"          ,                 [ 100 ], "mapped"],
	["durDev"        ,                   [ 1 ],         ],
	["rates"         , [ 1, 1, 1, 1, 1, 1, 1 ], "mapped"],
	["rateDev"       ,                   [ 1 ], "mapped"],
	["bufPos"        ,                 [ 0.5 ], "mapped"],
	["bufPosDev"     ,                   [ 0 ],         ],
	["envGrain"      ,                  [ -1 ],         ],
	["panC"          ,                   [ 0 ],         ],
	["panSpread"     ,                   [ 0 ],         ],
	["amp"           ,                 [ 0.4 ], "mapped"],
	["gate"          ,                   [ 1 ],         ],
	["fFreq"         ,                [ 5000 ],         ],
	["revMix"        ,                [ 0.33 ], "mapped"],
	["revRoom"       ,                 [ 0.5 ], "mapped"],
	["revDamp"       ,                 [ 0.2 ], "mapped"],
	["gainLow"       ,                   [ 1 ], "mapped"],
	["gainMid"       ,                   [ 1 ], "mapped"],
	["gainHigh"      ,                   [ 1 ], "mapped"]
];

// project path
~projectPath = PathName.new(thisProcess.nowExecutingPath).parentPath;

// SOME DEFAULT PARAMETERS
~fsrMin = 0;
~fsrMax = 4095;
~shakeMin = 0;
~shakeMax = 1;
~toggle = 0; // used  to turn on/off fsr calibration

// Dictionnary containing calibration results
~calibrationVals = Dictionary.with(*[
	\fsr -> [0, 4095],
	\shakeThresh -> [0, 2],
	\shakeMax -> [0, 6]
]);

~triBandF1 = 500;
~triBandF2 = 8000;

// Possible transpositions
~setRates = [
	[1, 1, 1, 1, 1, 1, 1],
	[1, 1, 1, 1/2, 1/2, 2, 2],
	[1, 1, 3/2, 3/2, 1/2, 3/4, 2],
	[1, 1/2, 2, 3/2, 5/4, 3/4, 5/8],
];

// Dictionary of SynthDef arguments
~synthDef = ~granParam.collect{
	arg item, i;
	var dic;
	if(item[2] == "mapped") {
		// create a Dictionary for each argument that is mapped
		dic = Dictionary();
		// argument name
		dic.add(\arg -> item[0]);
		// argument initial value(s)
		dic.add(\init -> item[1]);
	}
};
~synthDef = ~synthDef.reject({|item| item.isNil});


////////////////////////////////
//3. define piece-specific functions
////////////////////////////////

// function returns an array of objects assigned to a key in an array of Dictionaries
~arrayKey = {
	arg list, key;
	list.collect({
		arg item, i;
		item[key];
	});
};

// create buffers for soundfiles
// Reads only first channel in case there are some stereo files
~makeBuffers = {
	~buffs = PathName(~projectPath ++ ~audio).entries.collect({
		arg item, index;
		Buffer.readChannel(s, item.fullPath, channels:0);
	});
	"--------------------------------".postln;"        Buffers created".postln;"--------------------------------".postln;
};

// Buffer release function
~freeBuff = {
	arg buffers=nil;
	buffers.do({
		arg item;
		item.free;
	});
};

// Calibration Function
~calibrationFunc = {
	arg onOff=0, bus=0, dict=nil, key=nil;
	var arr=[], val, minVal=4095, maxVal=0;

	if(onOff == 1) {
		~calibRoutine = Routine{

			loop{
				val = bus.getSynchronous;

				if( arr.size < 10,
					{
						arr = arr.add(val);
					},{
						arr = arr.add(val);
						arr = arr.shift(-1);
						arr = arr.keep(10);
					}
				);
				minVal = minVal.min(arr.mean);
				maxVal = maxVal.max(arr.mean);
				(key ++ " min value: " ++ minVal.round(0.001) ++ " - " ++ key ++ " max value: " ++ maxVal.round(0.001)).postln;

				dict[key] = [minVal, maxVal];
				0.01.wait;
			}
		};
		~calibRoutine.play;
	}{
		~calibRoutine.stop;
	};

};

// Create control busses when server has booted
~makeBusses = {
	var bus = 0;
	// Dictionary of busses, keys are DMI source names
	~busDmi = Dictionary.new;
	~tStickParam.do({
		arg item;
		if(item[2] == "mapped") {
			~busDmi.add((~tStick ++ item[0]) -> Bus.control(s, item[1].asInteger));
			bus = bus + item[1].asInteger;
		};
	});

	("      " ++ bus.asString ++" DMI control busses").postln;

	// Dictionary of busses, keys are Synth arguments names
	bus = 0;
	~busSynth = Dictionary.new;
	~arrayKey.value(~synthDef, \arg).do({
		arg item, i;
		// bus number of channels is the size of the parameter initial value
		~busSynth.add(item -> Bus.control(s, ~synthDef[i][\init].size));
		bus = bus + ~synthDef[i][\init].size;
	});
	~busSynth.add(\fx -> Bus.audio(s,2));
	~busSynth.add(\lim -> Bus.audio(s,2));
	("     " ++ bus.asString ++" Synth control busses").postln;

	"Control and audio busses created".postln;"--------------------------------".postln;
};

// TBC Eli Fieldsteel tutorials
~cleanup = {
	s.newBusAllocators;
	ServerBoot.removeAll;
	ServerTree.removeAll;
	ServerQuit.removeAll;
};

// Cretate Synth mapping the interface control busses to sound parameters control busses
~makeBusMappings = {
	s.bind({
		~mappingGrp = Group.new;
		{
			// mapping for Synth parameter bufPos
			var mapBufPos;
			mapBufPos = In.kr(~busDmi[~tStick ++ "/raw/accl"].subBus(0), 1);
			mapBufPos = mapBufPos.lincurve(-10, 10, 0, 1, 0, nil);
			Out.kr(~busSynth["bufPos"], mapBufPos);
		}.play(~mappingGrp);

		{
			// mapping for Synth parameter dens    ||||||||RETRAVAILLER LE CALCUL DE DENSITÉ|||||||
			var mapDens;
			mapDens = In.kr(~busDmi[~tStick ++ "/instrument/touch/all"], 1);
			// mapDens.poll;
			mapDens = mapDens.lincurve(0.1, 0.75, 5, 120, 3.1, nil) // MAX 0.75
			* (0.5 * In.kr(~busDmi[~tStick ++ "/raw/fsr"], 1).linlin(~fsrMin, ~fsrMax, 0, 1, nil) + 1);
			Out.kr(~busSynth["dens"], mapDens);
			// mapDens.poll(label: "density");
			//
		}.play(~mappingGrp);

		{
			// mapping for Synth parameter gDur    ||||||||RETRAVAILLER LE CALCUL |||||||
			var mapGrDur;
			mapGrDur = In.kr(~busDmi[~tStick ++ "/raw/fsr"], 1).linlin(~calibrationVals[\fsr][0], ~calibrationVals[\fsr][1], 0, 1, nil);
			mapGrDur = mapGrDur.lincurve(0, 1, 5, 500, 4, nil);
			// mapGrDur.poll(label: "gDur");
			Out.kr(~busSynth["gDur"], mapGrDur);
			//
		}.play(~mappingGrp);

		{
			// mapping for Synth parameter amp
			var mapAmp, touchAll;
			touchAll = In.kr(~busDmi[~tStick ++ "/instrument/touch/all"], 1);
			// amp is 0 unless more than 10% of the surface is touched
			mapAmp = touchAll.lincurve(0, 1, 1, 0.2, 12.1, nil) * (touchAll > 0.1).if(1, 0) * 0.7; // CHALLENGE THRESHOLD W/ NEW CAPSENSE
			Out.kr(~busSynth["amp"], mapAmp);
			//
		}.play(~mappingGrp);

		{
			// mapping for Synth parameter rates
			var mapRates, touchMid, discrete;
			discrete = In.kr(~busDmi[~tStick ++ "/instrument/touch/discrete"], 30);
			touchMid = (discrete[7..22].sum / 16 * 4).round(1.0);
			// touchMid.poll;
			mapRates = Select.kr(touchMid, [DC.kr(~setRates[0]), DC.kr(~setRates[1]), DC.kr(~setRates[2]), DC.kr(~setRates[3])]);
			Out.kr(~busSynth["rates"], mapRates);
		}.play(~mappingGrp);

		{
			// mapping for Synth parameter rateDev !!!!!!!!!TUNE SHAKE!!!!!!!!!!!
			var mapRateDev;
			mapRateDev = In.kr(~busDmi[~tStick ++ "/instrument/shakexyz"].subBus(0), 1);
			mapRateDev = mapRateDev.lincurve(0, 2, 1.0, 1.1, 0, \min); // clip only minimum deviation
			Out.kr(~busSynth["rateDev"], mapRateDev);
		}.play(~mappingGrp);

		{
			// mapping for Synth parameter gainLow, gainMid, gainHigh
			var mapGainLow, mapGainMid, mapGainHigh, gyro;
			gyro = In.kr(~busDmi[~tStick ++ "/raw/gyro"], 3);
			mapGainLow = gyro[2].abs * 2;
			mapGainMid = gyro[0] * 8;
			mapGainHigh = gyro[1] * 6;
			Out.kr(~busSynth["gainLow"],mapGainLow);
			Out.kr(~busSynth["gainMid"], mapGainMid);
			Out.kr(~busSynth["gainHigh"], mapGainHigh);
		}.play(~mappingGrp);

		{
			// mapping for Synth parameter revMix, revRoom, revDamp
			var mapRevMix, mapRevRoom, mapRevDamp, gyro;
			gyro = In.kr(~busDmi[~tStick ++ "/raw/gyro"], 3);
			mapRevMix = (gyro[0].abs + gyro[1].abs + gyro[2].abs).lincurve(0, 0.5, 0.2, 0.8, -5.4, nil);
			mapRevRoom = (gyro[0].abs + gyro[1].abs + gyro[2].abs) / 3;
			mapRevDamp = (gyro[0].abs + gyro[1].abs + gyro[2].abs) / 4;
			Out.kr(~busSynth["revMix"],mapRevMix);
			Out.kr(~busSynth["revRoom"], mapRevRoom);
			Out.kr(~busSynth["revDamp"], mapRevDamp);
		}.play(~mappingGrp);
	})
};

// Create audio Synth
~makeNodes = {
	s.bind({
		~mainGrp = Group.new;
		~fxGrp = Group.after(~mainGrp);
		~limGrp = Group.after(~fxGrp);

		// 3 band Synth
		~triBandSynth = Synth(\triBand, [
			\in, ~busSynth[\fx],
			\freq1, ~triBandF1,
			\freq2, ~triBandF2,
			\gainLow, 1.0,
			\gainMid, 1.0,
			\gainHigh, 1.0,
			// \out, ~busSynth[\lim],
		], ~fxGrp);
		//
		// reverb Synth (tail of the fx group)
		~revSynth = Synth.tail(~fxGrp, \reverb, [\in, ~busSynth[\fx],
			\mix, 0.33,
			\room, 0.5,
			\damp, 0.2,
			// 	\out, ~busSynth[\lim],
		], ~fxGrp);

		// limiter Synth
		~limitSynth = Synth(\comp, [\in, ~busSynth[\fx], \thesh, -3.dbamp, \out, ~out], ~limGrp);

		// start a Synth and map the arguments to the control busses
		~synth =  Synth(\granulator, [
			\sndBuf, ~buffs[0],
			\dens, 10,
			\sync, 0.75,
			\gDur, 100,
			\durDev, 1.0,
			\rate, 1,
			\rateDev, 1,
			\bufPos, 0.2,
			\bufPosDev, 0,
			\envGrain, -1,
			\panC, 0,
			\panSpread, 0.5,
			\amp, 0.0,
			\out, ~busSynth[\fx]
		], ~mainGrp);

	});
	"         Nodes created".postln;"--------------------------------".postln;
};

~makeMaps = {
	// Wait to make sure Synth are created
	"       Creating mappings".postln;
	32.do{0.1.wait; "-".post;};
	"".postln;
	s.bind({

		// mappings of \granulator
		// ~synth.map(\sndBuf, ~busSynth["sndBuf"]);
		~synth.map(\dens, ~busSynth["dens"]);
		// ~synth.map(\sync, ~busSynth["sync"]);
		~synth.map(\gDur, ~busSynth["gDur"]);
		// ~synth.map(\durDev, ~busSynth["durDev"]);
		~synth.map(\rates, ~busSynth["rates"]);
		~synth.map(\rateDev, ~busSynth["rateDev"]);
		~synth.map(\bufPos, ~busSynth["bufPos"]);
		~synth.map(\bufPosDev, ~busSynth["bufPosDev"]);
		// ~synth.map(\envGrain, ~busSynth["envGrain"]);
		// ~synth.map(\panC, ~busSynth["panC"]);
		// ~synth.map(\panSpread, ~busSynth["panSpread"]);
		~synth.map(\amp, ~busSynth["amp"]);
		// ~synth.map(\gate, ~busSynth["gate"]);
		// ~synth.map(\out, ~busSynth["out"]);

		// mappings of \triBand
		~triBandSynth.map(\gainLow, ~busSynth["gainLow"]);

		// mappings of \reverb
		~revSynth.map(\mix, ~busSynth["revMix"]);
		~revSynth.map(\room, ~busSynth["revRoom"]);
		~revSynth.map(\damp, ~busSynth["revDamp"]);
	});
	"           DMI READY".postln;"--------------------------------".postln;
};

////////////////////////////////
// OSC message reception
////////////////////////////////

// Create OSCdef listening to webmapper output (an OSCdef can be identified by its key)



// FAIRE UN DICTIONNAIRE POUR ASSOCIER UN PARAM À UN BUS

~makeOSCdef = {

	// GUI for battery check
	~batteryOSC = "/battery/percentage";
	~winBatt = Window("/" ++ ~tStick ++ ~batteryOSC, Rect(10, 710, 300, 32)).front;
	~slider = MultiSliderView(~winBatt, Rect(0, 0, 300, 32));
	~slider.indexIsHorizontal_(false);
	~slider.indexThumbSize_(30);
	~slider.elasticMode_(1);
	~slider.size_(1);
	~slider.isFilled_(1);	// Battery Check
	OSCdef(\batteryCheck, {
		arg msg;
		// (~tStick ++ " Battery: " ++ (msg[1]/100)).postln;
		defer{~slider.value_([msg[1]/100])};
	}, ~tStick ++ ~batteryOSC, recvPort: ~recvPort);

	// Assign OSC data to control busses
	~busDmi.keys.do({
		arg item, i;
		// ~busDmi[item].postln;
		OSCdef(item, {
			arg msg;
			// Remove the addres from the OSC message
			msg.removeAt(0);
			//
			msg = msg.reshape(~busDmi[item].numChannels);
			~busDmi[item].setn(msg);
		}, item, recvPort: ~recvPort);
	});

	// FSR and shakeX Calibration
	OSCdef(\calibration, {
		arg msg;
		var tog;

		~toggle = (~toggle + 1)%8;

		case
		{ ~toggle == 1 } {
			~mappingGrp.free; // frees mapping nodes -> cuts off sound
			~calibrationFunc.(1, ~busDmi[~tStick ++ "/raw/fsr"], ~calibrationVals, \fsr);
			"FSR Calibration Started".postln;

		}
		{ ~toggle == 3 } {
			~calibrationFunc.(0);
			~calibrationFunc.(1, ~busDmi[~tStick ++ "/instrument/shakexyz"].subBus(0), ~calibrationVals, \shakeThresh);
			"FSR Calibration Completed".postln;
			"Shake Threshold Calibration Started".postln;

		}
		{ ~toggle == 5 } {
			~calibrationFunc.(0);
			~calibrationFunc.(1, ~busDmi[~tStick ++ "/instrument/shakexyz"].subBus(0), ~calibrationVals, \shakeMax);
			"Shake Threshold Calibration Completed".postln;
			"Maximum Shake Calibration Started".postln;

		}
		{ ~toggle == 7 } {
			~calibrationFunc.(0);
			"Maximum Shake Calibration Completed".postln;
			~makeBusMappings.();
		}
	}, ~tStick ++ "/instrument/button/tap", recvPort: ~recvPort);

	"        OSCdef created".postln;"--------------------------------".postln;
};

////////////////////////////////
//4. register functions with ServerBoot/Quit/Tree
////////////////////////////////
ServerBoot.add(~makeBuffers);
ServerBoot.add(~makeBusses);
ServerBoot.add(~makeOSCdef);
ServerQuit.add(~cleanup);


////////////////////////////////
//5. boot server
////////////////////////////////

"--------------------------------".postln;"         BOOTING SERVER".postln;"--------------------------------".postln;

// wait for boot function
s.waitForBoot({

	s.sync;
	"--------------------------------".postln;"         SERVER BOOTED".postln;"--------------------------------".postln;

	////////////////
	//6a. SynthDefs
	////////////////

	// Granulator SynthDef
	SynthDef(\granulator, {
		arg dens=10, sync=1, gDur=100, durDev=1, sndBuf=nil,rateDev=1,
		bufPos=0, bufPosDev=0, envGrain=(-1),
		panC=0, panSpread=0,
		gate=1, amp=0.4,
		atk=0.1, rel=1.0,
		out=0;
		var trig, durCtrl, rateGen, rate, rateCtrl, posCtrl, panCtrl, sig, envDyn;

		// array of triggers (size is maximum number of streams)
		// trig = GaussTrig.kr(dens/1 ! 1, 1-sync);
		trig = GaussTrig.kr(dens, 1-sync);

		// convert grain duration from ms to s
		gDur = gDur/1000;
		durCtrl = gDur * LFNoise1.kr(100).exprange(1/durDev, durDev);

		// rate as random value in an array ||||WIP||||
		rateGen = Drand(\rates.kr(~setRates[0]), inf);
		rate = Demand.kr(trig, 0,rateGen);

		// rate + random deviation
		rateCtrl = rate * LFNoise1.kr(100).exprange(1/rateDev, rateDev);

		// randomize grain position
		posCtrl = LFNoise1.kr(100).bipolar(bufPosDev); // deviation, bufPosDev is normalized
		posCtrl = bufPos + posCtrl; // initial position +deviation

		panCtrl = panC + LFNoise1.kr(10).bipolar(panSpread);


		sig = GrainBuf.ar(
			2, // replace with the number of streams
			trig,
			durCtrl,
			sndBuf,
			rateCtrl,
			posCtrl,
			2,
			panCtrl,
			envGrain,
			512
		);
		envDyn = EnvGen.kr(Env.asr(atk, 1.0, rel), gate, doneAction:2);

		sig = sig * envDyn * amp;
		// sig.poll;
		Out.ar(out, sig);
	}).add;

	// 3 band filter
	SynthDef(\triBand, {
		arg in=0, out=0, freq1=500, freq2=8000, gainLow=1.0, gainMid=1.0, gainHigh=1.0;
		var sig, sigLow, sigMid, sigHigh;
		sig = In.ar(in, 2);
		sig = BLowShelf.ar(sig, freq1, 1, gainLow-gainMid);
		sig = BHiShelf.ar(sig, freq2, 1, gainHigh-gainMid);
		sig = gainMid.dbamp * sig;
		ReplaceOut.ar(in, sig);
	}).add;

	// reverb
	SynthDef(\reverb, {
		arg in=0, out=0, mix=0, room=0.5, damp=0.5;
		var sig;
		mix = mix.lag(0.1);
		room = room.lag(0.1);
		damp = damp.lag(0.1);
		sig = In.ar(in, 2);
		sig = FreeVerb2.ar(
			sig[0],
			sig[1],
			mix,
			room,
			damp,
		);
		ReplaceOut.ar(in, sig);
	}).add;

	// security compressor
	SynthDef(\comp, {
		arg in=0, out=0, thresh=0.5;
		in = In.ar(in, 24);
		in = Compander.ar(in , in, thresh, 1.0, 0.1, 0.005);
		Out.ar(out, in);
	}).add;

	s.sync;

	////////////////
	//6b. Register remaining functions
	////////////////

	// remove eventually (not fit for large values)
	// ~scope = Stethoscope(s, ~busSynth.size, 0, rate:\control);
	// ~oscScope = Stethoscope(s, ~busDmi.values.collect{|item| item.numChannels;}.sum, 0, rate:\control);
	// Stethoscope(s, ~busSynth["rates"].numChannels, ~busSynth["rates"].index, rate:\control);

	ServerMeter(s, 2, 2);
	FreqScope.new;
	s.plotTree;

	ServerTree.add(~makeNodes); //

	s.sync;

	ServerTree.add(~makeBusMappings); // Add mapping nodes

	s.sync;

	ServerTree.add(~makeMaps); // Maps Synth parameters to control busses
	s.freeAll;

	s.sync;
});
// end of wait for boot function
)
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                      END MAIN CODE                                                         //
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Create a SCOPE function...



~synth.set(\sndBuf, ~buffs[0]);
~synth.set(\sndBuf, ~buffs[3ù]);
