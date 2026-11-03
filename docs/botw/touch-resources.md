# BOTW touch resource disposition

Generated from [the editable inventory](../../dm/games/01007EF00011E000/touch_ui_inventory.json) by `python3 dm/tools/botw_touch_progress.py`. Change the inventory and regenerate this page.

Every scanned layout is listed, including passive HUDs, backgrounds and shared parts. The JSON retains exact resource hashes, owner/component links, control declarations and classification reasons. New/changed resources must be classified before completion can pass. The actions themselves are in the [implementation checklist](touch-implementation.md).

| Layout | Role | Action requirements |
| --- | --- | --- |
| `AkashiNum_00` | passive layer | No independent menu action |
| `AmiiboWindow_00` | interactive screen | core.back, core.dialogue.choices, system.ack, system.dlc_amiibo |
| `AppAlbum_00` | interactive screen | applet.album, core.back, core.focus.direct, core.swipe.page |
| `AppCamera_00` | interactive screen | applet.camera, camera.shutter, camera.back, camera.self_portrait, camera.album, camera.framing_focus, camera.zoom, camera.selfie_pose |
| `AppHome_00` | interactive screen | apphome.pages, core.back, core.footer.action |
| `AppMap_00` | interactive screen | core.back, core.footer.action, map.pan_zoom, map.stamp_warp_header |
| `AppMapDungeon_00` | interactive screen | applet.dungeon, core.back |
| `AppPictureBook_00` | interactive screen | applet.picture_book, core.back, core.focus.direct |
| `AppSystemWindow_00` | interactive screen | core.back, core.dialogue.choices, system.ack |
| `AppSystemWindowNoBtn_00` | passive layer | system.ack.no_button_wait |
| `AppTool_00` | interactive screen | applet.tool, core.back, core.native_target.dispatch |
| `BootUp_00` | passive layer | No independent menu action |
| `BtnDialog_00` | reusable component | core.native_target.dispatch |
| `BtnScrollBar_07` | reusable component | No independent menu action |
| `ChallengeWin_00` | passive layer | No independent menu action |
| `ChangeController_00` | passive layer | system.controller_pairing |
| `ChangeControllerNN_00` | passive layer | system.controller_pairing |
| `ControllerWindow_00` | interactive screen | core.back, core.dialogue.choices, system.controller_pairing, system.controller_manual |
| `Cursor_00` | reusable component | No independent menu action |
| `DemoName_00` | passive layer | No independent menu action |
| `DemoNameEnemy_00` | passive layer | No independent menu action |
| `DemoStart` | visual only | intro.passive_transitions |
| `DLCSinJuAkashiNum_00` | passive layer | No independent menu action |
| `DLCWindow_00` | interactive screen | core.back, core.dialogue.choices, system.ack, system.dlc_amiibo |
| `DoCommand_00` | passive layer | No independent menu action |
| `End_00` | visual only | ending.passive_artwork |
| `EnergyMeterDLC_00` | passive layer | No independent menu action |
| `ErrorViewer_00` | interactive screen | system.error_viewer |
| `Fade_00` | passive layer | No independent menu action |
| `FadeDemo_00` | passive layer | No independent menu action |
| `FadeStatus_00` | passive layer | No independent menu action |
| `GameOver_00` | interactive screen | core.back, core.dialogue.choices, gameover.choices |
| `GamePadBG_00` | passive layer | No independent menu action |
| `GameTitle_00` | visual only | intro.passive_transitions |
| `HardMode_00` | interactive screen | intro.advance_mode |
| `HardModeTextDLC_00` | passive layer | No independent menu action |
| `HomeMenuCapture_00` | visual only | No independent menu action |
| `HomeNixSign_00` | passive layer | No independent menu action |
| `KeyBoradTextArea_00` | interactive screen | horse.name_entry, system.keyboard_text |
| `KeyNum_00` | visual only | No independent menu action |
| `KologNum_00` | passive layer | No independent menu action |
| `LastComplete_00` | visual only | intro.passive_transitions |
| `LoadingWeapon_00` | passive layer | No independent menu action |
| `LoadSaveIcon_00` | passive layer | No independent menu action |
| `MainDungeon_00` | passive layer | No independent menu action |
| `MainHardMode_00` | visual only | intro.passive_transitions |
| `MainHorse_00` | passive layer | horse.hud |
| `MainScreen3D_00` | passive layer | No independent menu action |
| `MainScreen_00` | interactive screen | scope.native_actions |
| `MainScreenHeartIchigekiDLC_00` | passive layer | No independent menu action |
| `MainScreenMS_00` | passive layer | No independent menu action |
| `MainShortCut_00` | passive layer | No independent menu action |
| `MamoNum_00` | passive layer | No independent menu action |
| `Message3D_00` | passive layer | No independent menu action |
| `Message_00` | interactive screen | core.back, core.dialogue.body, core.dialogue.choices, message.variants |
| `MessageDemo_00` | interactive screen | core.back, core.dialogue.body, core.dialogue.choices, message.variants |
| `MessageGet_00` | interactive screen | core.back, core.dialogue.body, core.dialogue.choices, message.variants, item_get.inventory |
| `MessageSp_00` | interactive screen | core.back, core.dialogue.body, core.dialogue.choices, message.variants |
| `MessageTips_00` | interactive screen | core.back, core.dialogue.body, core.dialogue.choices, message.variants |
| `MessageTipsPauseMenu_00` | interactive screen | core.back, core.dialogue.body, core.dialogue.choices, message.variants |
| `MessageTipsRunTime_00` | passive layer | No independent menu action |
| `MiniGame_00` | passive layer | No independent menu action |
| `OPtext_00` | visual only | intro.passive_transitions |
| `OptionWindow_00` | interactive screen | core.back, core.swipe.page, options.rows_values, core.value.adjust |
| `Pa_AppMapOpenEf_00` | reusable component | No independent menu action |
| `PaABtn_00` | reusable component | No independent menu action |
| `PaABtnApp_00` | reusable component | No independent menu action |
| `PaAkashiEf_00` | reusable component | No independent menu action |
| `PaAkashiEfBDLC_00` | reusable component | No independent menu action |
| `PaAkashiEfGDLC_00` | reusable component | No independent menu action |
| `PaAkashiEfRDLC_00` | reusable component | No independent menu action |
| `PaAkashiEfYDLC_00` | reusable component | No independent menu action |
| `PaAllControllerTipsNN_00` | reusable component | No independent menu action |
| `PaAppAlbumPage_00` | reusable component | No independent menu action |
| `PaAppAlbumPhoto_00` | reusable component | core.native_target.dispatch |
| `PaAppAlbumPhotoBtn_00` | reusable component | core.native_target.dispatch |
| `PaAppAlbumPhotoCapture_00` | reusable component | No independent menu action |
| `PaAppAllRadarGauge_00` | reusable component | No independent menu action |
| `PaAppArrow_00` | reusable component | No independent menu action |
| `PaAppBrokenText_00` | reusable component | No independent menu action |
| `PaAppCameraFocus_00` | reusable component | No independent menu action |
| `PaAppCategoryBtnS_00` | reusable component | core.native_target.dispatch |
| `PaAppDungeonBtn_00` | reusable component | core.native_target.dispatch |
| `PaAppDungeonBtnElectric_00` | reusable component | core.native_target.dispatch |
| `PaAppDungeonBtnNextMove_00` | reusable component | core.native_target.dispatch |
| `PaAppDungeonBtnNextMoveFinalDLC_00` | reusable component | core.native_target.dispatch |
| `PaAppDungeonBtnNextMoveFire_00` | reusable component | core.native_target.dispatch |
| `PaAppDungeonMapCursor_00` | reusable component | No independent menu action |
| `PaAppGauge_00` | reusable component | No independent menu action |
| `PaAppGear_00` | reusable component | No independent menu action |
| `PaAppMapComp_00` | reusable component | No independent menu action |
| `PaAppMapCursor_00` | reusable component | No independent menu action |
| `PaAppMapName_00` | reusable component | No independent menu action |
| `PaAppMapNorthMark_00` | reusable component | No independent menu action |
| `PaAppMapPinBtn_00` | reusable component | core.native_target.dispatch |
| `PaAppMapSensor_00` | reusable component | No independent menu action |
| `PaAppMapSensorSetting_00` | reusable component | No independent menu action |
| `PaAppMapStampBox_00` | reusable component | No independent menu action |
| `PaAppMapStampListBtn_00` | reusable component | core.native_target.dispatch |
| `PaAppMapTemp2_00` | reusable component | No independent menu action |
| `PaAppMapTemp_00` | reusable component | No independent menu action |
| `PaAppMapTime2_00` | reusable component | No independent menu action |
| `PaAppMapTime_00` | reusable component | No independent menu action |
| `PaAppPageNavi_00` | reusable component | No independent menu action |
| `PaAppPauseInfoParam_00` | reusable component | No independent menu action |
| `PaAppPauseInfoParam_01` | reusable component | No independent menu action |
| `PaAppPauseInfoParam_04` | reusable component | No independent menu action |
| `PaAppPictureBookBalloon_00` | reusable component | No independent menu action |
| `PaAppPictureBookInfo_00` | reusable component | core.native_target.dispatch |
| `PaAppPictureBookItem_00` | reusable component | No independent menu action |
| `PaAppPictureBookPage_00` | reusable component | No independent menu action |
| `PaAppPictureBookPhotoBtn_00` | reusable component | core.native_target.dispatch |
| `PaAppPictureBookPhotoSensor_00` | reusable component | No independent menu action |
| `PaAppSystemWindow_00` | reusable component | No independent menu action |
| `PaArrow_00` | reusable component | No independent menu action |
| `PaArrowPointer_00` | reusable component | No independent menu action |
| `PaBoxedCursor_00` | reusable component | No independent menu action |
| `PaCameraPointer_00` | reusable component | scope.native_actions |
| `PaCameraPointerPin_00` | reusable component | No independent menu action |
| `PaCategoryBtnS_00` | reusable component | core.native_target.dispatch |
| `PaCategoryChallenge5_00` | reusable component | No independent menu action |
| `PaChallengeListBtn_00` | reusable component | core.native_target.dispatch |
| `PaChallengeMark_00` | reusable component | No independent menu action |
| `PaChallengeWin_00` | reusable component | No independent menu action |
| `PaCmnZLBtn_00` | reusable component | No independent menu action |
| `PaCmnZLBtnApp_00` | reusable component | No independent menu action |
| `PaCmnZRBtn_00` | reusable component | No independent menu action |
| `PaCmnZRBtnApp_00` | reusable component | No independent menu action |
| `PaColorBtn_00` | reusable component | core.native_target.dispatch |
| `PaCommonBtnThin_00` | reusable component | core.native_target.dispatch |
| `PaCommonBtnThinAction_00` | reusable component | core.native_target.dispatch |
| `PaCommonBtnThinApp_00` | reusable component | core.native_target.dispatch |
| `PaCommonBtnThinIcon_00` | reusable component | core.native_target.dispatch |
| `PaCommonBtnThinIconAct_00` | reusable component | core.native_target.dispatch |
| `PaCommonBtnThinIconAct_01` | reusable component | core.native_target.dispatch |
| `PaCommonBtnThinS_00` | reusable component | core.native_target.dispatch |
| `PaCommonBtnTitle_00` | reusable component | core.native_target.dispatch |
| `PaDataFileBtn_00` | reusable component | core.native_target.dispatch |
| `PaDLCTips_00` | reusable component | No independent menu action |
| `PaDLCTipsBefore_00` | reusable component | No independent menu action |
| `PaDLCTipsPage_00` | reusable component | No independent menu action |
| `PaDoCommandA_00` | reusable component | No independent menu action |
| `PaDoCommandB_00` | reusable component | No independent menu action |
| `PaDoCommandKey_00` | reusable component | No independent menu action |
| `PaDoCommandKeyB_00` | reusable component | No independent menu action |
| `PaDoCommandKeyC_00` | reusable component | No independent menu action |
| `PaDoCommandKeyNNA_00` | reusable component | No independent menu action |
| `PaDoCommandKeyNNB_00` | reusable component | No independent menu action |
| `PaDoCommandKeyNNC_00` | reusable component | No independent menu action |
| `PaDoCommandL_00` | reusable component | No independent menu action |
| `PaDoCommandX_00` | reusable component | No independent menu action |
| `PaDoCommandY_00` | reusable component | No independent menu action |
| `PaEiketuEfB_00` | reusable component | No independent menu action |
| `PaEiketuEfBDLC_00` | reusable component | No independent menu action |
| `PaEiketuEfG_00` | reusable component | No independent menu action |
| `PaEiketuEfGDLC_00` | reusable component | No independent menu action |
| `PaEiketuEfR_00` | reusable component | No independent menu action |
| `PaEiketuEfRDLC_00` | reusable component | No independent menu action |
| `PaEiketuEfY_00` | reusable component | No independent menu action |
| `PaEiketuEfYDLC_00` | reusable component | No independent menu action |
| `PaEnemyGauge_00` | reusable component | No independent menu action |
| `PaEnemyGaugeL_00` | reusable component | No independent menu action |
| `PaEnergyMeterDLC_00` | reusable component | No independent menu action |
| `PaFadeBar_00` | reusable component | No independent menu action |
| `PaFadeIconAncient_00` | reusable component | No independent menu action |
| `PaFadeIconDLC_00` | reusable component | No independent menu action |
| `PaFadeIconNum_00` | reusable component | No independent menu action |
| `PaGanbariGauge_01` | reusable component | No independent menu action |
| `PaGanbariGaugeEx_00` | reusable component | No independent menu action |
| `PaGuideKeyApp_00` | reusable component | No independent menu action |
| `PaGuideKeyNormal_00` | reusable component | No independent menu action |
| `PaGuideKeySimple_00` | reusable component | No independent menu action |
| `PaGuideKeySmoke_00` | reusable component | No independent menu action |
| `PaHeartTraceGaugeSlim_00` | reusable component | No independent menu action |
| `PaHeartTraceGaugeSlimMS_00` | reusable component | No independent menu action |
| `PaHeartTraceGaugeSlimWL_00` | reusable component | No independent menu action |
| `PaHorseBtn_00` | reusable component | core.native_target.dispatch |
| `PaHorseSpeedUpIcon_00` | reusable component | No independent menu action |
| `PaIconBtn_00` | reusable component | core.native_target.dispatch |
| `PaIconBtnApp_00` | reusable component | core.native_target.dispatch |
| `PaIconBtnSpIcon_00` | reusable component | No independent menu action |
| `PaIconChallenge_00` | reusable component | No independent menu action |
| `PaIconElect_00` | reusable component | No independent menu action |
| `PaIconParamLB_00` | reusable component | No independent menu action |
| `PaIconSmoke_00` | reusable component | No independent menu action |
| `PaInformation_00` | reusable component | No independent menu action |
| `PaItemPointer_00` | reusable component | No independent menu action |
| `PaLoadingIconNoWait_00` | reusable component | No independent menu action |
| `PaLocationName_00` | reusable component | No independent menu action |
| `PaLocationNameHokoraS_00` | reusable component | No independent menu action |
| `PaLocationNameS_00` | reusable component | No independent menu action |
| `PaMap_00` | reusable component | No independent menu action |
| `PaMapCursorDLC_00` | reusable component | No independent menu action |
| `PaMapDLCGaugeL_00` | reusable component | No independent menu action |
| `PaMapDLCPlayIcon_00` | reusable component | No independent menu action |
| `PaMapIcon_00` | reusable component | No independent menu action |
| `PaMapIconBikeBtnDLC_00` | reusable component | No independent menu action |
| `PaMapIconBtn_00` | reusable component | No independent menu action |
| `PaMapIconBtnDecide_00` | reusable component | No independent menu action |
| `PaMapIconCastle_00` | reusable component | No independent menu action |
| `PaMapIconChallenge_00` | reusable component | No independent menu action |
| `PaMapIconDead_00` | reusable component | No independent menu action |
| `PaMapIconDungeon_00` | reusable component | No independent menu action |
| `PaMapIconDungeonDLC_00` | reusable component | No independent menu action |
| `PaMapIconEtc_00` | reusable component | No independent menu action |
| `PaMapIconGuardian_00` | reusable component | No independent menu action |
| `PaMapIconHatago_00` | reusable component | No independent menu action |
| `PaMapIconHorseBtn_00` | reusable component | No independent menu action |
| `PaMapIconKolog_00` | reusable component | No independent menu action |
| `PaMapIconLabo_00` | reusable component | No independent menu action |
| `PaMapIconPlayer_00` | reusable component | No independent menu action |
| `PaMapIconPlayerDLC_00` | reusable component | No independent menu action |
| `PaMapIconRemainsElectric_00` | reusable component | No independent menu action |
| `PaMapIconRemainsFire_00` | reusable component | No independent menu action |
| `PaMapIconRemainsWater_00` | reusable component | No independent menu action |
| `PaMapIconRemainsWind_00` | reusable component | No independent menu action |
| `PaMapIconShopBougu_00` | reusable component | No independent menu action |
| `PaMapIconShopColor_00` | reusable component | No independent menu action |
| `PaMapIconShopJewel_00` | reusable component | No independent menu action |
| `PaMapIconShopYadoya_00` | reusable component | No independent menu action |
| `PaMapIconShopYorozu_00` | reusable component | No independent menu action |
| `PaMapIconStartPoint_00` | reusable component | No independent menu action |
| `PaMapIconTower_00` | reusable component | No independent menu action |
| `PaMapIconVillage_00` | reusable component | No independent menu action |
| `PaMapIconWarpDLC_00` | reusable component | No independent menu action |
| `PaMapIconWolfLink_00` | reusable component | No independent menu action |
| `PaMapIconYunbo_00` | reusable component | No independent menu action |
| `PaMapLocationName_00` | reusable component | No independent menu action |
| `PaMapPlayer_00` | reusable component | core.native_target.dispatch |
| `PaMapStampMaxNum_00` | reusable component | No independent menu action |
| `PaMessage_00` | reusable component | No independent menu action |
| `PaMessageBtn_00` | reusable component | core.native_target.dispatch |
| `PaMessageDungeon_00` | reusable component | No independent menu action |
| `PaMessageDungeonTitle_00` | reusable component | No independent menu action |
| `PaMessageTips_00` | reusable component | No independent menu action |
| `PaMessageTipsAmiibo_00` | reusable component | No independent menu action |
| `PaMessageTipsDrcImageNN_00` | reusable component | No independent menu action |
| `PaMessageTipsDrcImgAmiiboNN_00` | reusable component | No independent menu action |
| `PaMiniGameCheckPoint_00` | reusable component | No independent menu action |
| `PaMiniGameDistance_00` | reusable component | No independent menu action |
| `PaMiniGameFinish_00` | reusable component | No independent menu action |
| `PaMiniGameGolf_00` | reusable component | No independent menu action |
| `PaMiniGameMato_00` | reusable component | No independent menu action |
| `PaMiniGameRecord_00` | reusable component | No independent menu action |
| `PaMiniGameTimer_00` | reusable component | No independent menu action |
| `PaNoticeItem_00` | reusable component | No independent menu action |
| `PaNoticeMark_00` | reusable component | No independent menu action |
| `PaNoticeZ_00` | reusable component | No independent menu action |
| `PaNumberArrow_00` | reusable component | No independent menu action |
| `PaNumberArrowMsg_00` | reusable component | No independent menu action |
| `PaOptionBtn_00` | reusable component | core.native_target.dispatch |
| `PaOptionBtnL_00` | reusable component | core.native_target.dispatch |
| `PaOptionBtnLevel_00` | reusable component | core.native_target.dispatch |
| `PaOptionSlideBtn_00` | reusable component | No independent menu action |
| `PaPage20_00` | reusable component | No independent menu action |
| `PaPage5_00` | reusable component | No independent menu action |
| `PaPageChallenge5_00` | reusable component | No independent menu action |
| `PaPageControllerList_00` | reusable component | No independent menu action |
| `PaPageNavi_00` | reusable component | No independent menu action |
| `PaPauseGear_00` | reusable component | No independent menu action |
| `PaPauseIconCapture_00` | reusable component | No independent menu action |
| `PaPauseInfoHaveNum_00` | reusable component | No independent menu action |
| `PaPauseInfoParam_00` | reusable component | No independent menu action |
| `PaPauseInfoParam_01` | reusable component | No independent menu action |
| `PaPauseInfoParam_04` | reusable component | No independent menu action |
| `PaPauseInfoParam_05` | reusable component | No independent menu action |
| `PaPauseInfoParamCook_00` | reusable component | No independent menu action |
| `PaPauseInfoSetBonus_00` | reusable component | No independent menu action |
| `PaPauseQuest_00` | reusable component | No independent menu action |
| `PaPauseRecipeText_00` | reusable component | No independent menu action |
| `PaPauseSave_00` | reusable component | No independent menu action |
| `PaPauseSpIconNew_00` | reusable component | No independent menu action |
| `PaPauseStar_00` | reusable component | No independent menu action |
| `PaPauseTipsPage_00` | reusable component | No independent menu action |
| `PaPauseTipsPageCopy_00` | reusable component | No independent menu action |
| `PaPickUpWin_00` | reusable component | No independent menu action |
| `PaPictureLoad_00` | reusable component | No independent menu action |
| `PaPlayerStatusUp_00` | reusable component | No independent menu action |
| `PaPlayerStatusUpAll_00` | reusable component | No independent menu action |
| `PaPlusMinus_00` | reusable component | No independent menu action |
| `PaQuestName_00` | reusable component | No independent menu action |
| `PaRstickGuide_00` | reusable component | No independent menu action |
| `PaSaveIcon_00` | reusable component | No independent menu action |
| `PaSeekPadDecoText_00` | reusable component | No independent menu action |
| `PaSeekPadScanningLine_00` | reusable component | scope.native_actions |
| `PaShopHorseCapture_00` | reusable component | No independent menu action |
| `PaShopHorseInfo_01` | reusable component | No independent menu action |
| `PaShopHorseInfoParam_00` | reusable component | No independent menu action |
| `PaShopHorseInfoParam_01` | reusable component | No independent menu action |
| `PaShopItemHave_00` | reusable component | No independent menu action |
| `PaShopItemIcon_00` | reusable component | No independent menu action |
| `PaShopItemName_00` | reusable component | No independent menu action |
| `PaShopListBtn_00` | reusable component | core.native_target.dispatch |
| `PaShopMaterial_00` | reusable component | No independent menu action |
| `PaShopPage20_00` | reusable component | No independent menu action |
| `PaShopSubInfo_00` | reusable component | No independent menu action |
| `PaShortCutIcon_00` | reusable component | core.native_target.dispatch |
| `PaShortCutIconCross_00` | reusable component | No independent menu action |
| `PaShortCutIconCrossNN_00` | reusable component | No independent menu action |
| `PaSinJu_00` | reusable component | No independent menu action |
| `PaSoundGauge_00` | reusable component | No independent menu action |
| `PaSystemWindow_02` | reusable component | No independent menu action |
| `PaTempMeter_00` | reusable component | No independent menu action |
| `PaTempMeterGauge_00` | reusable component | No independent menu action |
| `PaTempMeterGauge_01` | reusable component | No independent menu action |
| `PaTempMeterGaugeLoop_00` | reusable component | No independent menu action |
| `PaThrowingPointer_00` | reusable component | No independent menu action |
| `PaTime_00` | reusable component | No independent menu action |
| `PaTitleBtn_00` | reusable component | core.native_target.dispatch |
| `PauseMenu_00` | interactive screen | applet.album, applet.picture_book, core.back, core.native_target.dispatch, inventory.actions, inventory.category, inventory.sort_rotate_recipe, map.stamp_warp_header, options.rows_values, pause.home, quest.rows_categories |
| `PauseMenuBG_00` | passive layer | No independent menu action |
| `PauseMenuEiketsu_00` | interactive screen | applet.album, applet.picture_book, core.back, core.native_target.dispatch, inventory.actions, inventory.category, inventory.sort_rotate_recipe, map.stamp_warp_header, options.rows_values, pause.home, quest.rows_categories |
| `PauseMenuInfo_00` | passive layer | core.footer.action |
| `PauseMenuMantan_00` | interactive screen | applet.album, applet.picture_book, core.back, core.native_target.dispatch, inventory.actions, inventory.category, inventory.sort_rotate_recipe, map.stamp_warp_header, options.rows_values, pause.home, quest.rows_categories |
| `PauseMenuRecipe_00` | interactive screen | applet.album, applet.picture_book, core.back, core.native_target.dispatch, inventory.actions, inventory.category, inventory.sort_rotate_recipe, map.stamp_warp_header, options.rows_values, pause.home, quest.rows_categories |
| `PaWarpEfDLC_00` | reusable component | No independent menu action |
| `PaWeather_00` | reusable component | No independent menu action |
| `PickUpWin_00` | passive layer | No independent menu action |
| `ReadyGo_00` | passive layer | No independent menu action |
| `Rupee_00` | passive layer | No independent menu action |
| `SaveTransferWindow_00` | interactive screen | core.back, core.dialogue.choices, system.save_transfer |
| `SeekPadMenuBG_00` | passive layer | No independent menu action |
| `ShopBG_00` | passive layer | No independent menu action |
| `ShopBtnList15_00` | interactive screen | core.back, core.dialogue.choices, core.dialogue.quantity, core.focus.direct |
| `ShopBtnList20_00` | interactive screen | core.back, core.dialogue.choices, core.dialogue.quantity, core.focus.direct |
| `ShopBtnList5_00` | interactive screen | core.back, core.dialogue.choices, core.dialogue.quantity, core.focus.direct |
| `ShopHorse_00` | interactive screen | core.back, core.focus.direct, horse.name_entry, horse.registry |
| `ShopInfo_00` | passive layer | No independent menu action |
| `Skip_00` | prompt screen | cutscene.skip |
| `SousaGuide_00` | interactive screen | guide.shrine |
| `StaffRoll_00` | visual only | ending.passive_artwork |
| `StaffRollDLC_00` | interactive screen | ending.continue_skip |
| `SystemWindow_00` | interactive screen | core.back, core.dialogue.choices, system.ack |
| `SystemWindow_01` | interactive screen | core.back, core.dialogue.choices, system.ack |
| `SystemWindowNoBtn_00` | passive layer | system.ack.no_button_wait |
| `Thanks_00` | visual only | ending.passive_artwork |
| `Time_00` | passive layer | No independent menu action |
| `Title_00` | interactive screen | title.load |
| `WolfLinkHeartGauge_00` | passive layer | No independent menu action |
