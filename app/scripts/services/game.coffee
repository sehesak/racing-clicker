'use strict'

angular.module('racingApp').factory 'Cache', -> class Cache
  constructor: ->
    # Never cleared; hacky way to pass messages that get cleared on reload
    @firstSpawn = {}
    @onUpdate()
    @onRespec()
    @forever = {}

  onPeriodic: ->
    @_lastPeriodicClear = new Date().getTime()
    @upgradeIsUpgradable = {}
    @upgradeEstimateSecsUntilBuyablePeriodic = {}

  onUpdate: ->
    @onPeriodic()
    @onTick()
    @tinyUrl = {}
    @stats = {}
    @eachCost = {}
    @eachProduction = {}
    @upgradeTotalCost = {}
    @producerPathProdEach = {}
    @producerPathCoefficients = {}
    @unitRawCount = {}
    @unitCap = {}
    @unitCapPercent = {}
    @upgradeEstimateSecsUntilBuyableCacheSafe = {}
    @unitTwinMult = {}
    @upgradeIsCostMet = {}
    @upgradeIsNextCostMet = {}
    @untilUpdate = {}

  onTick: ->
    @unitCount = {}
    @velocity = {}
    @totalProduction = {}
    @upgradeMaxCostMet = {}
    @unitMaxCostMet = {}
    @unitMaxCostMetOfVelocity = {}
    @unitMaxCosts = {}
    @untilTick = {}
    delete @tutorialStep

    # clear periodic caches every few seconds
    if new Date().getTime() - @_lastPeriodicClear >= 3000
      @onPeriodic()

  onRespec: ->
    @unitVisible = {}
    @upgradeVisible = {}

###*
 # @ngdoc service
 # @name racingApp.game
 # @description
 # # game
 # Factory in the racingApp.
###
angular.module('racingApp').factory 'Game', (unittypes, upgradetypes, achievements, util, $log, Upgrade, Unit, Achievement, Tab, Cache, $location, dialogService, $rootScope, backfill, $timeout, env) -> class Game
  constructor: (@session) ->
    @_init()
  _init: ->
    @isFixHeight = _.contains window.location.search, 'fixheight'

    @_units =
      list: _.map unittypes.list, (unittype) =>
        new Unit this, unittype
    @_units.byName = _.indexBy @_units.list, 'name'
    @_units.bySlug = _.indexBy @_units.list, (u) -> u.unittype.slug

    @_upgrades =
      list: _.map upgradetypes.list, (upgradetype) =>
        new Upgrade this, upgradetype
    @_upgrades.byName = _.indexBy @_upgrades.list, 'name'

    @_achievements =
      list: _.map achievements.list, (achievementtype) =>
        new Achievement this, achievementtype
    @_achievements.byName = _.indexBy @_achievements.list, 'name'
    @achievementPointsPossible = achievements.pointsPossible()
    $log.debug 'possiblepoints: ', @achievementPointsPossible

    @tabs = Tab.buildTabs @_units.list

    @skippedMillis = 0
    @gameSpeed = 1
    @session.state.skippedMillis ?= 0
    @session.state.elapsedMillis ?= 0
    @session.state.welcomeShowed ?= false
    @session.state.tutorialClosed ?= false

    for item in [].concat @_units.list, @_upgrades.list, @_achievements.list
      item._init()
    for item in @_units.list
      item._init2()

    @cache = new Cache()

    @_deferedSave = _.debounce =>
      $timeout =>
        @session.save()
        @cache.onUpdate()
    , 250

    # tick to reified-time, then to now. this ensures things explode here, instead of later, if they've gone back in time since saving
    delete @now
    @tick @session?.state?.date?.reified
    @tick()

  diffMillis: ->
    @_realDiffMillis() * @gameSpeed + @skippedMillis
  _realDiffMillis: ->
    return 0 if @paused
    ret = @now.getTime() - @session.state.date.reified.getTime()
    return Math.max 0, ret
  diffSeconds: ->
    @diffMillis() / 1000

  elapsedMillis: ->
    new Decimal(@_realDiffMillis()).times(@gameSpeed).plus(@session.state.skippedMillis).plus(@session.state.elapsedMillis).toNumber()
  elapsedSeconds: ->
    @elapsedMillis() / 1000

  skipMillis: (millis) ->
    millis = Math.floor millis
    @skippedMillis += millis
    @session.state.skippedMillis += millis
  skipDuration: (duration) ->
    @skipMillis duration.asMilliseconds()
  skipTime: (args...) ->
    @skipDuration moment.duration args...

  setGameSpeed: (speed) ->
    @reify()
    @gameSpeed = speed

  totalSkippedMillis: ->
    @session.state.skippedMillis
  totalSkippedDuration: ->
    moment.duration @totalSkippedMillis()
  dateStarted: ->
    @session.state.date.started
  momentStarted: ->
    moment @dateStarted()

  tick: (now=new Date(), skipExpire=false) ->
    return if @paused
    util.assert now, "can't tick to undefined time", now
    if (not @now) or @now <= now
      @now = now
      @cache.onTick()
    else
      # system clock problem! don't whine for small timing errors, but don't update the clock either.
      # TODO I hope this accounts for DST
      diffMillis = @now.getTime() - now.getTime()
      util.assert diffMillis <= 120 * 1000, "tick tried to go back in time. System clock problem?", @now, now, diffMillis

  elapsedStartMillis: ->
    @now.getTime() - @session.state.date.started.getTime()
  timestampMillis: ->
    @elapsedStartMillis() + @totalSkippedMillis()

  unit: (unitname) ->
    if _.isUndefined unitname
      return undefined
    if not _.isString unitname
      # it's a unittype?
      unitname = unitname.name
    @_units.byName[unitname]
  unitBySlug: (unitslug) ->
    if unitslug
      @_units.bySlug[unitslug]
  units: ->
    _.clone @_units.byName
  unitlist: ->
    _.clone @_units.list

  # TODO deprecated, remove in favor of unit(name).count(secs)
  count: (unitname, secs) ->
    return @unit(unitname).count secs

  counts: -> @countUnits()
  countUnits: ->
    _.mapValues @units(), (unit, name) ->
      unit.count()
  countUpgrades: ->
    _.mapValues @upgrades(), (upgrade, name) ->
      upgrade.count()
  getNewlyUpgradableUnits: ->
    (u for u in @unitlist() when u.isNewlyUpgradable() and u.isVisible())

  upgrade: (name) ->
    if not _.isString name
      name = name.name
    @_upgrades.byName[name]
  upgrades: ->
    _.clone @_upgrades.byName
  upgradelist: ->
    _.clone @_upgrades.list
  availableUpgrades: (costPercent=undefined) ->
    (u for u in @upgradelist() when u.isVisible() and u.isUpgradable costPercent, true)
  availableAutobuyUpgrades: (costPercent=undefined) ->
    (u for u in @availableUpgrades(costPercent) when u.isAutobuyable())
  ignoredUpgrades: ->
    (u for u in @upgradelist() when u.isVisible() and u.isIgnored())
  unignoredUpgrades: ->
    (u for u in @upgradelist() when u.isVisible() and not u.isIgnored())

  resourcelist: ->
    return @unitlist().concat @upgradelist()

  achievement: (name) ->
    if not _.isString name
      name = name.name
    @_achievements.byName[name]
  achievements: ->
    _.clone @_achievements.byName
  achievementlist: ->
    _.clone @_achievements.list
  achievementsSorted: ->
    _.sortBy @achievementlist(), (a) ->
      a.earnedAtMillisElapsed()
  achievementPoints: ->
    util.sum _.map @achievementlist(), (a) -> a.pointsEarned()
  achievementPercent: ->
    @achievementPoints() / @achievementPointsPossible

  # Store the 'real' counts, and the time last counted, in the session.
  # Usually, counts are calculated as a function of last-reified-count and time,
  # see count().
  # You must reify before making any changes to unit counts or effectiveness!
  # (So, units that increase the effectiveness of other units AND are produced
  # by other units - ex. derivative clicker mathematicians - can't be supported.)
  reify: (skipSeconds=0) ->
    secs = @diffSeconds()
    # in 0.1s the change should be small enough to risk incorrect counts for speed
    return if secs < 0.1
    counts = @counts secs
    _.extend @session.state.unittypes, counts
    @skippedMillis = 0
    @session.state.skippedMillis += @diffMillis() - @_realDiffMillis()
    @session.state.elapsedMillis += @diffMillis()
    @session.state.date.reified = @now
    @cache.onUpdate()
    util.assert 0 == @diffSeconds(), 'diffseconds != 0 after reify!'

  save: ->
    @withSave ->

  importSave: (encoded, transient) ->
    @session.importSave encoded, transient
    # Force-clear various caches.
    @_init()
    backfill.run this
    dialogService.openDialog 'importsplash' if $location.search().importsplash

  # A common pattern: change something (reifying first), then save the changes.
  # Use game.withSave(myFunctionThatChangesSomething) to do that.
  withSave: (fn) ->
    @reify()
    ret = fn()
    # reify a second time for swarmwarp; https://github.com/erosson/swarm/issues/241
    # Unnecessary for other things, but mostly harmless.
    @reify()
    @session.save()
    @cache.onUpdate()
    return ret

  withDeferedSave: (fn) ->
    @reify()
    ret = fn()
    @_deferedSave()
    return ret

  withUnreifiedSave: (fn) ->
    ret = fn()
    @session.save()
    return ret

  reset: (transient=false) ->
    @session.reset()
    @_init()
    for unit in @unitlist()
      unit._setCount unit.unittype.init or 0
    if not transient
      @save()

  ascendEnergySpent: ->
    energy = @unit 'energy'
    return energy.spent()
  ascendCost: (opts={}) ->
    if opts.spent?
      spent = new Decimal opts.spent
    else
      spent = @ascendEnergySpent()
    ascends = @unit('ascension').count()
    ascendPenalty = Decimal.pow 1.12, ascends
    #return Math.ceil 999999 / (1 + spent/50000)
    # initial cost 5 million, halved every 50k spent, increases 20% per past ascension
    costVelocity = new Decimal(50000).times(@unit('mutagen').stat 'ascendCost', 1)
    return ascendPenalty.times(5e6).dividedBy(Decimal.pow 2, spent.dividedBy costVelocity).ceil()
  ascendCostCapDiff: (cost=@ascendCost()) ->
    return cost.minus @unit('energy').capValue()
  ascendCostPercent: (cost=@ascendCost()) ->
    Decimal.min 1, @unit('energy').count().dividedBy cost
  ascendCostDurationSecs: (cost = @ascendCost()) ->
    energy = @unit 'energy'
    if cost.lessThan energy.capValue()
      return energy.estimateSecsUntilEarned(cost).toNumber()
  ascendCostDurationMoment: (cost) ->
    if (secs=@ascendCostDurationSecs cost)?
      return moment.duration secs, 'seconds'
  ascendLvl: ->
    ascension = @unit 'ascension'
    return Decimal.ln(Decimal.max 1, ascension.count()).ceil().toNumber()
  experienceGainFromAscend: (experienceGain) ->
    return @cache.untilTick['experienceGainFromAscend'] ?= do =>
      experienceGain ? @unit('fake_fame').count().times(Decimal.ln(@unit('experience').count()) .plus(1) .pow(@ascendLvl()) ).plus(@unit('experience').count().times(Decimal.pow(@ascendLvl(), @ascendLvl())))
  experienceAfterAscend: (experienceGain) ->
    return @cache.untilTick['experienceAfterAscend'] ?= do =>
      @unit('experience').count().plus @experienceGainFromAscend(experienceGain)
  experienceToEffect: (experience) ->
    ef = @unit('experience').effect[0].calcStats({}, {}, experience)
    for key, value of ef
      return value
  currentExperienceEffect: ->
    return @cache.untilTick['currentExperienceEffect'] ?= do =>
      @experienceToEffect @unit('experience').count()
  experienceEffectGainFromAscend: (experienceGain) ->
    return @cache.untilTick['experienceEffectGainFromAscend'] ?= do =>
      @experienceEffectAfterAscend(experienceGain).minus @currentExperienceEffect()
  experienceEffectAfterAscend: (experienceGain) ->
    return @cache.untilTick['experienceEffectAfterAscend'] ?= do =>
      @experienceToEffect @experienceAfterAscend(experienceGain)
  hasBuyOut: ->
    switch @ascendLvl()
      when 0 then return @unit('car10').isVisible()
      when 1 then return @unit('car9').isVisible()
      when 2 then return @unit('car8').isVisible()
      when 3 then return @unit('car7').isVisible()
      else return @unit('car6').isVisible()
  ascendOffers: ->
    offers = []

    ascendLvl = @ascendLvl()
#    if ascendLvl < 2
    offers.push
      exp: @experienceGainFromAscend()
      effect: @experienceEffectAfterAscend()
#    else if ascendLvl < 10
#      offers.push
#        exp: @experienceGainFromAscend()
#        effect: @experienceEffectAfterAscend()
#        persistUnit: "tech#{ascendLvl}"
#        persistUnitCount: 1000

    # skip offers for now
    return offers

    return offers if ascendLvl < 1

    maxCar = 1
    for i in [25..1]
      if not @unit("car#{i}").count().isZero()
        maxCar = i
        if not @upgrade("car#{i}_upgrade").count().isZero()
          return offers
        break

    maxTech = 0
    for i in [13..1]
      if not @unit("tech#{i}").count().isZero()
        maxTech = i
        break

    if 1 < ascendLvl < maxCar
      offers.push
        exp: @experienceGainFromAscend().times 0.1
        effect: @experienceEffectGainFromAscend(@experienceGainFromAscend().times 0.1)
        persistCarLevels: ascendLvl

    if ascendLvl < maxTech
      offers.push
        exp: @experienceGainFromAscend().times 0.1
        effect: @experienceEffectGainFromAscend(@experienceGainFromAscend().times 0.1)
        persistUnit: "tech#{Decimal.min(12, ascendLvl).toNumber()+1}"
        persistUnitCount: 1

    offers

  ascend: (opts={}) ->
#    if !free and @ascendCostPercent() < 1
#      throw new Error "We require more resources (ascension cost)"
    @withSave =>
      # hardcode ascension bonuses. TODO: spreadsheetify
      fake_fame = @unit 'fake_fame'
      experience = @unit 'experience'
      ascension = @unit 'ascension'
      experience._addCount @experienceGainFromAscend(opts?.exp)
      fake_fame._setCount 0
      ascension._addCount 1

      return if env.isDebugEnabled and opts.debug

      @session.state.date.restarted = @now
      # do not use @reset(): we don't want achievements, etc. reset
      @_init()
      # show tutorial message for first ascension. must go after @_init, or cache is cleared
      if ascension.count().equals(1)
        @cache.firstSpawn.ascension = true
      for unit in @unitlist()
        continue if opts?.persistCarLevels >= unit.name.match(/^car(\d+)$/)?[1]
        if opts?.persistUnit is unit.name
          unit._setCount opts.persistUnitCount ? 1
          continue
        if not unit.type.persist?
          unit._setCount if unit.unittype.init and @ascendLvl() > 0 then Decimal.pow(unit.unittype.init, @ascendLvl()) else unit.unittype.init or 0
      for upgrade in @upgradelist()
        continue if opts?.persistCarLevels >= upgrade.name.match(/^car(\d+)_buy$/)?[1]
        if not upgrade.type.persist?
          upgrade._setCount 0

  respecRate: ->
    1.00
  respecCost: ->
    @ascendCost().times(@respecCostRate).ceil()
  respecCostRate: 0.3
  respecCostCapDiff: -> @ascendCostCapDiff @respecCost()
  respecCostPercent: -> @ascendCostPercent @respecCost()
  respecCostDurationSecs: -> @ascendCostDurationSecs @respecCost()
  respecCostDurationMoment: -> @ascendCostDurationMoment @respecCost()
  isRespecCostMet: ->
    @unit('energy').count().greaterThanOrEqualTo @respecCost()
  respecSpent: ->
    mutagen = @unit 'mutagen'
    # upgrade costs are weird - upgrade costs rely on other upgrades, which breaks spending tracking.
    # ignore them, relying on the mutateHidden upgrade for the true cost.
    ignores = {}
    for up in mutagen.upgrades.list
      ignores[up.name] = true
    # Upgrades come with a free(ish) unit too, so remove their cost. (Mostly for unit tests, doesn't really matter.)
    return mutagen.spent(ignores).minus(@upgrade('mutatehidden').count())
  respec: ->
    @withSave =>
      if not @isRespecCostMet()
        throw new Error "We require more resources"
      cost = @respecCost()
      @unit('energy')._subtractCount cost
      # respeccing wipes spent-energy. energy cost of respeccing counts toward spent-energy *after* spent-energy is wiped
      spent = @ascendEnergySpent().minus cost
      @unit('respecEnergy')._addCount spent
      @_respec()

  respecFree: ->
    @withSave =>
      if not @unit('freeRespec').count().greaterThan(0)
        throw new Error "We require more resources"
      @unit('freeRespec')._subtractCount 1
      @_respec()

  _respec: ->
    mutagen = @unit 'mutagen'
    spent = @respecSpent()
    for resource in mutagen.spentResources()
      resource._setCount 0
    mutagen._addCount spent.times(@respecRate()).floor()
    @cache.onRespec()
    util.assert mutagen.spent().isZero(), "respec didn't refund all mutagen!"

  showBackfillProgress: ->
    @pause()
    @modalInstance = dialogService.openDialog('backfillProgress')
  closeBackfillProgress: ->
    @modalInstance?.opened.then =>
      @modalInstance.dismiss()
      @resume()

  pause: ->
    @paused = true
    return @paused
  resume: ->
    @paused = false
    return @paused

angular.module('racingApp').factory 'game', (Game, session, env) ->
  game = new Game session
  window.game = game if env.isDebugEnabled
  game
