objectdef obj_Configuration_SpiderTankReps inherits obj_Configuration_Base
{
	method Initialize()
	{
		This[parent]:Initialize["SpiderTankReps"]
	}

	method Set_Default_Values()
	{
		This.ConfigRef:AddSetting[ReservedTargetLocks, 2]
		This.ConfigRef:AddSetting[RepShieldThreshold, 50]
		This.ConfigRef:AddSetting[RepArmorThreshold, 80]
		This.ConfigRef:AddSetting[StopRepShieldThreshold, 90]
		This.ConfigRef:AddSetting[StopRepArmorThreshold, 99]
		This.ConfigRef:AddSetting[CapOutThreshold, 30]
		This.ConfigRef:AddSetting[LogLevelBar, LOG_INFO]
	}
	
	Setting(int, ReservedTargetLocks, SetReservedTargetLocks)
	Setting(int, RepShieldThreshold, SetRepShieldThreshold)
	Setting(int, StopRepShieldThreshold, SetStopRepShieldThreshold)
	Setting(int, RepArmorThreshold, SetRepArmorThreshold)
	Setting(int, StopRepArmorThreshold, SetStopRepArmorThreshold)
	Setting(int, CapOutThreshold, SetCapOutThreshold)
	Setting(int, LogLevelBar, SetLogLevelBar)
}

objectdef obj_SpiderTankReps inherits obj_StateQueue
{
	; Avoid name conflict with common config.
	variable obj_Configuration_SpiderTankReps Config

	; This is all of our sqlite variables
	variable sqlitedb SpiderTankData
	; This will be our query 
	variable sqlitequery sortedList

	variable bool IsOtherPilotsDetected = FALSE

	variable bool BotRunningFlag = FALSE
	
	;What reps we got
	variable bool WeArmorRep
	variable bool WeShieldRep
	
	;How many things can we target
	variable int MaxTarget = ${MyShip.MaxLockedTargets}

	variable int64 MyRepTarget = 0

	; Chain break detection - track last successful rep time
	variable int LastSuccessfulRepTime = 0
	; Emergency rep tracking - CharID of critical target we're emergency repping
	variable int64 EmergencyRepTarget = 0

	variable obj_TargetList PCs
	variable obj_TargetList NPCs
	variable collection:int AttackTimestamp

	method Initialize()
	{
		This[parent]:Initialize

		DynamicAddMiniMode("SpiderTankReps", "SpiderTankReps")
		This.PulseFrequency:Set[500]

		This.NonGameTiedPulse:Set[TRUE]
		
		; Create or connect to our database. 
		SpiderTankData:Set[${SQLite.OpenDB["${Me.Name}SpiderTankData","${Script.CurrentDirectory}/Data/${Me.Name}SpiderTankData.sqlite3"]}]
		SpiderTankData:ExecDML["PRAGMA journal_mode=WAL;"]
		SpiderTankData:ExecDML["PRAGMA main.mmap_size=64000000"]
		SpiderTankData:ExecDML["PRAGMA main.cache_size=-64000;"]
		SpiderTankData:ExecDML["PRAGMA synchronous = normal;"]
		SpiderTankData:ExecDML["PRAGMA temp_store = memory;"]
		; Create our table in the database if it doesn't exist
		if !${SpiderTankData.TableExists["fleetList"]}
		{
			echo DEBUG - SpiderTankReps - Creating fleetList Table
			SpiderTankData:ExecDML["create table fleetList (CharID INTEGER PRIMARY KEY, CharName TEXT, ThreatLevel INTEGER, LastUpdate INTEGER, UpdateType TEXT);"]
		}
		if ${SpiderTankData.TableExists["fleetList"]}
		{
			echo DEBUG - SpiderTankReps - fleetList Table Exists - Check if we are in the file
			SpiderTankData:ExecDML["insert or ignore into fleetList (CharID, CharName, ThreatLevel, LastUpdate, UpdateType) values (${Me.ID}, "${Me.Name.ReplaceSubstring[','']}", 0, "${Time.Timestamp}", "initial");"]
		}

		; We need to create a list of participants.
		LavishScript:RegisterEvent[SR_Participants]
		Event[SR_Participants]:AttachAtom[This:ParticipantRecorder]
		
		This.LogLevelBar:Set[${Config.LogLevelBar}]
	}

	method Start()
	{
		AttackTimestamp:Clear

		if ${This.IsIdle}
		{
			This:LogInfo["Starting"]
			This:QueueState["SpiderTankReps"]
		}
	}
	
	method Stop()
	{
		This:Clear
	}

	method Shutdown()
	{
		SpiderTankData:ExecDML["drop table fleetList;"]
		SpiderTankData:ExecDML["Vacuum;"]	
		SpiderTankData:Close
		This:Clear
	}
	
	method ParticipantRecorder(int ParticipantID)
	{
		if ${SpiderTankData.TableExists["fleetList"]}
		{
			variable string pname = ${Entity[CharID == ${ParticipantID}].Name.ReplaceSubstring[','']}
			echo ["insert into fleetList (CharID, CharName, ThreatLevel, LastUpdate, UpdateType) values (${ParticipantID}, ${pname}, 0, ${Time.Timestamp}, initial);"]
			SpiderTankData:ExecDML["insert or ignore into fleetList (CharID, CharName, ThreatLevel, LastUpdate, UpdateType) values (${ParticipantID}, "${pname}", 0, "${Time.Timestamp}", "initial");"]

		}
	}
	
	method DetermineRepType()
	{
		if ${Ship.ModuleList_ArmorProjectors.Count} > 0
		{
			WeArmorRep:Set[TRUE]
		}
		if ${Ship.ModuleList_ShieldTransporters.Count} > 0
		{
			WeShieldRep:Set[TRUE]
		}
		
	}
	
	method ParticipantTrigger()
	{
		relay all "Event[SR_Participants]:Execute[${Me.CharID}]"
	}
	
	member:int TargetCount()
	{
		return ${Math.Calc[${Me.TargetCount} + ${Me.TargetingCount} + ${Config.ReservedTargetLocks}]}
	}

	; Helper method to validate if a target is valid for repping
	; Checks: entity exists, not warping, in range of rep modules
	member:bool IsValidRepTarget(int64 charID)
	{
		; Check entity exists
		if !${Entity[CharID == ${charID}](exists)}
		{
			return FALSE
		}

		; Check entity is not warping (Mode 3 = MOVE_WARPING)
		if ${Entity[CharID == ${charID}].Mode} == MOVE_WARPING
		{
			return FALSE
		}

		; Check range - use shield transporter range if we have them, otherwise armor projector range
		variable float repRange = 0
		if ${WeShieldRep} && ${Ship.ModuleList_ShieldTransporters.Count} > 0
		{
			repRange:Set[${Ship.ModuleList_ShieldTransporters.Range}]
		}
		elseif ${WeArmorRep} && ${Ship.ModuleList_ArmorProjectors.Count} > 0
		{
			repRange:Set[${Ship.ModuleList_ArmorProjectors.Range}]
		}

		if ${repRange} > 0 && ${Entity[CharID == ${charID}].Distance} > ${repRange}
		{
			return FALSE
		}

		return TRUE
	}

	; Find any valid fleet member to rep (used for chain break recovery)
	member:int64 FindAnyValidFleetTarget()
	{
		variable index:entity fleetEntities
		variable iterator fleetIter

		EVE:QueryEntities[fleetEntities, "IsPC = 1 && Distance > 0 && IsFleetMember = 1"]
		if ${fleetEntities.Used} > 0
		{
			fleetEntities:GetIterator[fleetIter]
			if ${fleetIter:First(exists)}
			{
				do
				{
					; Skip ourselves
					if ${fleetIter.Value.CharID} == ${Me.CharID}
					{
						continue
					}
					; Check if this is a valid rep target
					if ${This.IsValidRepTarget[${fleetIter.Value.CharID}]}
					{
						return ${fleetIter.Value.CharID}
					}
				}
				while ${fleetIter:Next(exists)}
			}
		}
		return 0
	}

	; Find critical fleet member (below 30% HP) for emergency repping
	member:int64 FindCriticalFleetTarget()
	{
		variable index:entity fleetEntities
		variable iterator fleetIter
		variable int64 criticalTarget = 0
		variable float lowestHP = 100

		EVE:QueryEntities[fleetEntities, "IsPC = 1 && Distance > 0 && IsFleetMember = 1"]
		if ${fleetEntities.Used} > 0
		{
			fleetEntities:GetIterator[fleetIter]
			if ${fleetIter:First(exists)}
			{
				do
				{
					; Skip ourselves
					if ${fleetIter.Value.CharID} == ${Me.CharID}
					{
						continue
					}

					; Check if this is a valid rep target
					if !${This.IsValidRepTarget[${fleetIter.Value.CharID}]}
					{
						continue
					}

					; Check HP based on rep type
					variable float currentHP = 100
					if ${WeShieldRep}
					{
						currentHP:Set[${fleetIter.Value.ShieldPct}]
					}
					elseif ${WeArmorRep}
					{
						currentHP:Set[${fleetIter.Value.ArmorPct}]
					}

					; If below 30% and lower than current lowest, mark as critical
					if ${currentHP} < 30 && ${currentHP} < ${lowestHP}
					{
						lowestHP:Set[${currentHP}]
						criticalTarget:Set[${fleetIter.Value.CharID}]
					}
				}
				while ${fleetIter:Next(exists)}
			}
		}
		return ${criticalTarget}
	}

	; Lock and rep the person below us in the list of participants, if we are the last row then we need to get the first row and lock and rep that person
	method LockAndRepNext()
	{
		This:LogInfo["LockAndRepNext: Start"]

		; Emergency rep override check (Fix #5)
		; If assigned chain partner is above 90% HP but another fleet member is below 30%, temporarily rep the critical target
		variable int64 criticalTarget = ${This.FindCriticalFleetTarget}
		if ${criticalTarget} != 0 && ${MyRepTarget} != 0
		{
			; Check if our normal chain partner is healthy (above 90%)
			variable float partnerHP = 100
			if ${WeShieldRep}
			{
				partnerHP:Set[${Entity[CharID == ${MyRepTarget}].ShieldPct}]
			}
			elseif ${WeArmorRep}
			{
				partnerHP:Set[${Entity[CharID == ${MyRepTarget}].ArmorPct}]
			}

			if ${partnerHP} > 90 && ${criticalTarget} != ${MyRepTarget}
			{
				This:LogWarning["EMERGENCY REP: Chain partner at ${partnerHP}% HP, switching to critical target ${criticalTarget}"]
				EmergencyRepTarget:Set[${criticalTarget}]
			}
			else
			{
				EmergencyRepTarget:Set[0]
			}
		}
		else
		{
			EmergencyRepTarget:Set[0]
		}

		; Ensure our fleetList table exists
		if (!${SpiderTankData.TableExists["fleetList"]})
		{
			This:LogInfo["fleetList table not found"]
			return
		}
		This:LogInfo["LockAndRepNext: table exists lets go!"]
		; Attempt to get the next row after our own character
		variable sqlitequery nextRowQuery
		nextRowQuery:Set[${SpiderTankData.ExecQuery["SELECT * FROM fleetList WHERE CharID > ${Me.ID} ORDER BY CharID ASC LIMIT 1;"]}]
		This:LogInfo["LockAndRepNext: nextRowQuery.NumRows = ${nextRowQuery.NumRows}"]
		if ((${nextRowQuery.NumRows} != NULL) && ${nextRowQuery.NumRows.Equal[1]} && !${nextRowQuery.GetFieldValue["CharID"].Equal[${Me.ID}]})
		{
			; We found a row with a CharID greater than ours
			MyRepTarget:Set[${nextRowQuery.GetFieldValue["CharID"]}]
			This:LogInfo["LockAndRepNext: Next row after our character is ${MyRepTarget}"]
		}
		else
		{
			; Our character is the last row – wrap around and select the first row.
			variable sqlitequery firstRowQuery
			firstRowQuery:Set[${SpiderTankData.ExecQuery["SELECT * FROM fleetList ORDER BY CharID ASC LIMIT 1;"]}]
			This:LogInfo["LockAndRepNext: firstRowQuery.NumRows = ${firstRowQuery.NumRows}"]
			if ((${firstRowQuery.NumRows} != NULL) && ${firstRowQuery.NumRows.Equal[1]} && !${firstRowQuery.GetFieldValue["CharID"].Equal[${Me.ID}]})
			{
				MyRepTarget:Set[${firstRowQuery.GetFieldValue["CharID"]}]
				This:LogInfo["LockAndRepNext: We are the last row, wrapping to first row. Target is ${MyRepTarget}"]
			}
			else
			{
				This:LogInfo["LockAndRepNext: No rows found in fleetList"]
			}
			firstRowQuery:Finalize
		}
		nextRowQuery:Finalize

		; Determine actual rep target (emergency override or normal chain partner)
		variable int64 actualRepTarget = ${MyRepTarget}
		if ${EmergencyRepTarget} != 0
		{
			actualRepTarget:Set[${EmergencyRepTarget}]
			This:LogInfo["Using emergency rep target: ${actualRepTarget}"]
		}

		; Validate rep target before proceeding (Fix #3)
		if ${actualRepTarget} != 0 && !${This.IsValidRepTarget[${actualRepTarget}]}
		{
			This:LogWarning["Rep target ${actualRepTarget} is not valid (out of range or warping)"]

			; Chain break detection (Fix #4) - check if we haven't had a successful rep in ~10 seconds
			if ${Math.Calc[${Time.Timestamp} - ${LastSuccessfulRepTime}]} > 10
			{
				This:LogWarning["CHAIN BREAK DETECTED: No successful rep in 10+ seconds, attempting recovery"]
				; Try to find any valid fleet member to rep
				variable int64 recoveryTarget = ${This.FindAnyValidFleetTarget}
				if ${recoveryTarget} != 0
				{
					actualRepTarget:Set[${recoveryTarget}]
					This:LogInfo["Chain break recovery: Found alternate target ${actualRepTarget}"]
				}
				else
				{
					This:LogWarning["Chain break recovery: No valid fleet targets found"]
					return
				}
			}
			else
			{
				return
			}
		}

		; Lock our rep target and start repping them
		This:LogInfo["LockAndRepNext: is our rep target set? ${actualRepTarget}"]
		if ${actualRepTarget} != 0
		{
			This:LogInfo["LockAndRepNext: Target is locked? ". ${Entity[CharID == ${actualRepTarget}].IsLockedTarget} . " & BeingTargeted? " . ${Entity[CharID == ${actualRepTarget}].BeingTargeted}]
			if (!${Entity[CharID == ${actualRepTarget}].IsLockedTarget} && !${Entity[CharID == ${actualRepTarget}].BeingTargeted})
			{
				Entity[CharID == ${actualRepTarget}]:LockTarget
				This:LogInfo["Locking target:  ${actualRepTarget}"]
			}

			; Activate shield rep if we have them
			if (${Entity[CharID == ${actualRepTarget}].IsLockedTarget} && ${WeShieldRep})
			{
				Ship.ModuleList_ShieldTransporters:ActivateAll[${Entity[CharID == ${actualRepTarget}].ID}]
				Ship.ModuleList_EnergyTransfer:ActivateAll[${Entity[CharID == ${actualRepTarget}].ID}]
				This:LogInfo["Activating shield rep on: ${actualRepTarget}"]
				; Update last successful rep time
				LastSuccessfulRepTime:Set[${Time.Timestamp}]
			}

			; Activate armor rep if we have them
			if (${Entity[CharID == ${actualRepTarget}].IsLockedTarget} && ${WeArmorRep})
			{
				Ship.ModuleList_ArmorProjectors:ActivateAll[${Entity[CharID == ${actualRepTarget}].ID}]
				Ship.ModuleList_EnergyTransfer:ActivateAll[${Entity[CharID == ${actualRepTarget}].ID}]
				This:LogInfo["Activating armor rep on: ${actualRepTarget}"]
				; Update last successful rep time
				LastSuccessfulRepTime:Set[${Time.Timestamp}]
			}
		}

		sortedList:Finalize
	}
	; Not currently being used, will use later.
	method RepDeactivation()
	{
		variable index:entity StopRepHelper
		variable iterator StopRepHelper2
		
		EVE:QueryEntities[StopRepHelper, "IsLockedTarget = 1"]
		if ${StopRepHelper.Used} > 0
		StopRepHelper:GetIterator[StopRepHelper2]
		if ${StopRepHelper2:First(exists)}
		{
			do
			{
				if ${Ship.ModuleList_ArmorProjectors.ActiveCount} > 0
				{
					if ${MyShip.CapacitorPct.Int} < ${Config.CapOutThreshold}
					{
						Ship.ModuleList_ArmorProjectors:DeactivateAll
					}
					if ${StopRepHelper2.Value.ArmorPct} > ${Config.StopRepArmorThreshold}
					{
						Ship.ModuleList_ArmorProjectors:DeactivateOn[${StopRepHelper2.Value.ID}]
					}
				}
				if ${Ship.ModuleList_ShieldTransporters.ActiveCount} > 0
				{
					if ${MyShip.CapacitorPct.Int} < ${Config.CapOutThreshold}
					{
						Ship.ModuleList_ShieldTransporters:DeactivateAll
					}
					if ${StopRepHelper2.Value.ShieldPct} > ${Config.StopRepShieldThreshold}
					{
						Ship.ModuleList_ShieldTransporters:DeactivateOn[${StopRepHelper2.Value.ID}]
					}
				}
			}
			while ${StopRepHelper2:Next(exists)}
		}
	}
	member:bool SpiderTankReps()
	{
		if !${ISXEVE.IsReady}
		{
			return FALSE
		}
		if ${Me.InStation}
		{
			return FALSE
		}

		; While currently jumping, Me.InSpace is false and status numbers will be null.
		if !${Client.InSpace}
		{
			This:LogDebug["Not in space, jumping?"]
			return FALSE
		}
		if ${MyShip.ToEntity.Mode} == MOVE_WARPING
		{
			return FALSE
		}
		This:ParticipantTrigger
		This:DetermineRepType
		This:LockAndRepNext
		This:RepDeactivation

		return FALSE
	}
}