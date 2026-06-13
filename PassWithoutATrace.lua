_addon.name = 'PassWithoutATrace'
_addon.author = 'gol-exe'
_addon.version = '1.0.0'
_addon.commands = {'passwithoutatrace', 'pwat'}

require('luau')
require('logger')
local res = require('resources')

local defaults = {
    useJig = true,
}
local settings = config.load(defaults)

local use_items = true

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local SNEAK_SPELL_ID = res.spells:with('name', 'Sneak').id
local INVIS_SPELL_ID = res.spells:with('name', 'Invisible').id
local SILENT_OIL_ID = res.items:with('name', 'Silent Oil').id
local PRISM_POWDER_ID = res.items:with('name', 'Prism Powder').id

local BUFF_SNEAK = 'Sneak'
local BUFF_INVISIBLE = 'Invisible'
local BUFF_LIGHT_ARTS = 'Light Arts'
local BUFF_ADDENDUM_WHITE = 'Addendum: White'
local BUFF_ACCESSION = 'Accession'

local SEARCH_BAGS = {0, 5, 6, 7}

local CAST_TIME_DELAY = 5
local JA_DELAY = 2
local ITEM_DELAY = 3.5
local ITEM_MOVE_DELAY = 0.6

-------------------------------------------------------------------------------
-- State
-------------------------------------------------------------------------------

local party_cache = {}
local action_queue = {}
local queue_active = false
local executing = false

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

local function chat(msg)
    windower.add_to_chat(207, '\30\02[PWAT]\30\01 ' .. msg)
end

local function get_active_buffs()
    local player = windower.ffxi.get_player()
    if not player then return {} end
    local buff_names = {}
    for _, id in ipairs(player.buffs) do
        if res.buffs[id] then
            buff_names[res.buffs[id].name] = true
        end
    end
    return buff_names
end

local function has_buff(name)
    return get_active_buffs()[name] or false
end

local function player_knows_spell(spell_id)
    local spells = windower.ffxi.get_spells()
    return spells and spells[spell_id] or false
end

local function get_spell_recast_seconds(spell_name)
    local spell = res.spells:with('name', spell_name)
    if not spell then return 0 end
    local recasts = windower.ffxi.get_spell_recasts()
    if not recasts or not recasts[spell.id] then return 0 end
    return recasts[spell.id] / 60
end

-------------------------------------------------------------------------------
-- Item Search (adapted from Itemizer)
-------------------------------------------------------------------------------

local function find_item_in_bags(item_id)
    for _, bag_id in ipairs(SEARCH_BAGS) do
        local bag_info = windower.ffxi.get_bag_info(bag_id)
        if bag_info and bag_info.enabled then
            local items = windower.ffxi.get_items(bag_id)
            for _, item in ipairs(items) do
                if item.id and item.id == item_id and item.id > 0 then
                    return {bag = bag_id, slot = item.slot, count = item.count}
                end
            end
        end
    end
    return nil
end

local function count_item_all_bags(item_id)
    local total = 0
    for _, bag_id in ipairs(SEARCH_BAGS) do
        local bag_info = windower.ffxi.get_bag_info(bag_id)
        if bag_info and bag_info.enabled then
            local items = windower.ffxi.get_items(bag_id)
            for _, item in ipairs(items) do
                if item.id and item.id == item_id and item.id > 0 then
                    total = total + item.count
                end
            end
        end
    end
    return total
end

local function ensure_item_in_inventory(item_id)
    local inv_items = windower.ffxi.get_items(0)
    for _, item in ipairs(inv_items) do
        if item.id and item.id == item_id and item.id > 0 then
            return true
        end
    end

    local inv_info = windower.ffxi.get_bag_info(0)
    if inv_info.count >= inv_info.max then
        chat('Inventory full, cannot retrieve item.')
        return false
    end

    for _, bag_id in ipairs({5, 6, 7}) do
        local bag_info = windower.ffxi.get_bag_info(bag_id)
        if bag_info and bag_info.enabled then
            local items = windower.ffxi.get_items(bag_id)
            for _, item in ipairs(items) do
                if item.id and item.id == item_id and item.id > 0 then
                    windower.ffxi.get_item(bag_id, item.slot, 1)
                    return true
                end
            end
        end
    end

    return false
end

-------------------------------------------------------------------------------
-- State Gathering
-------------------------------------------------------------------------------

local function gather_local_state()
    local player = windower.ffxi.get_player()
    if not player then return nil end

    local main_job = player.main_job
    local sub_job = player.sub_job
    local main_lvl = player.main_job_level
    local sub_lvl = player.sub_job_level

    local knows_sneak = player_knows_spell(SNEAK_SPELL_ID)
    local knows_invis = player_knows_spell(INVIS_SPELL_ID)

    local can_cast_sneak = false
    local can_cast_invis = false

    local sneak_jobs = {WHM = 20, RDM = 20, SCH = 20}
    local invis_jobs = {WHM = 25, RDM = 25, SCH = 25}

    if knows_sneak then
        local req = sneak_jobs[main_job]
        if req and main_lvl >= req then can_cast_sneak = true end
        req = sneak_jobs[sub_job]
        if req and sub_lvl >= req then can_cast_sneak = true end
    end

    if knows_invis then
        local req = invis_jobs[main_job]
        if req and main_lvl >= req then can_cast_invis = true end
        req = invis_jobs[sub_job]
        if req and sub_lvl >= req then can_cast_invis = true end
    end

    local has_light_arts = false
    local has_accession = false
    local has_spectral_jig = false

    if main_job == 'SCH' then
        has_light_arts = main_lvl >= 10
        has_accession = main_lvl >= 40
    end
    if sub_job == 'SCH' then
        if sub_lvl >= 10 then has_light_arts = true end
        if sub_lvl >= 40 then has_accession = true end
    end

    if main_job == 'DNC' and main_lvl >= 25 then
        has_spectral_jig = true
    end
    if sub_job == 'DNC' and sub_lvl >= 25 then
        has_spectral_jig = true
    end

    local oil_count = count_item_all_bags(SILENT_OIL_ID)
    local powder_count = count_item_all_bags(PRISM_POWDER_ID)

    local buffs = get_active_buffs()
    local buff_list = {}
    for name, _ in pairs(buffs) do
        buff_list[#buff_list + 1] = name
    end

    return {
        name = player.name,
        main_job = main_job,
        sub_job = sub_job,
        main_job_level = main_lvl,
        sub_job_level = sub_lvl,
        knows_sneak = knows_sneak,
        knows_invis = knows_invis,
        can_cast_sneak = can_cast_sneak,
        can_cast_invis = can_cast_invis,
        has_light_arts = has_light_arts,
        has_accession = has_accession,
        has_spectral_jig = has_spectral_jig,
        oil_count = oil_count,
        powder_count = powder_count,
        buffs = buffs,
        buff_list = buff_list,
    }
end

-------------------------------------------------------------------------------
-- IPC Communication
-------------------------------------------------------------------------------

local function serialize_state(state)
    local parts = {
        'PWAT:STATE',
        state.name,
        state.main_job,
        state.sub_job or 'NON',
        tostring(state.main_job_level),
        tostring(state.sub_job_level),
        state.can_cast_sneak and '1' or '0',
        state.can_cast_invis and '1' or '0',
        state.has_light_arts and '1' or '0',
        state.has_accession and '1' or '0',
        tostring(state.oil_count),
        tostring(state.powder_count),
        state.has_spectral_jig and '1' or '0',
        table.concat(state.buff_list, ','),
    }
    return table.concat(parts, '|')
end

local function deserialize_state(msg)
    local parts = {}
    local idx = 1
    for part in (msg .. '|'):gmatch('([^|]*)|') do
        parts[idx] = part
        idx = idx + 1
    end

    if idx - 1 < 13 then return nil end

    local buff_names = {}
    if parts[14] and parts[14] ~= '' then
        for name in parts[14]:gmatch('[^,]+') do
            buff_names[name] = true
        end
    end

    return {
        name = parts[2],
        main_job = parts[3],
        sub_job = parts[4] ~= 'NON' and parts[4] or nil,
        main_job_level = tonumber(parts[5]) or 0,
        sub_job_level = tonumber(parts[6]) or 0,
        can_cast_sneak = parts[7] == '1',
        can_cast_invis = parts[8] == '1',
        has_light_arts = parts[9] == '1',
        has_accession = parts[10] == '1',
        oil_count = tonumber(parts[11]) or 0,
        powder_count = tonumber(parts[12]) or 0,
        has_spectral_jig = parts[13] == '1',
        buffs = buff_names,
    }
end

local function broadcast_state()
    local state = gather_local_state()
    if not state then return end

    party_cache[state.name] = state
    windower.send_ipc_message(serialize_state(state))
end

-------------------------------------------------------------------------------
-- Action Queue Executor
-------------------------------------------------------------------------------

local function clear_queue()
    action_queue = {}
    queue_active = false
    executing = false
end

local function process_next_action()
    if #action_queue == 0 then
        queue_active = false
        executing = false
        chat('Action sequence complete.')
        return
    end

    executing = true
    local action = action_queue[1]
    local cmd = ''
    local delay = CAST_TIME_DELAY

    if action.type == 'ma' then
        local recast = get_spell_recast_seconds(action.name)
        if recast > 0 then
            coroutine.schedule(process_next_action, recast + 0.5)
            return
        end
        table.remove(action_queue, 1)
        local target = action.target or '<me>'
        cmd = '/ma "' .. action.name .. '" ' .. target
        delay = CAST_TIME_DELAY
    elseif action.type == 'ja' then
        table.remove(action_queue, 1)
        local target = action.target or '<me>'
        cmd = '/ja "' .. action.name .. '" ' .. target
        delay = JA_DELAY
    elseif action.type == 'item' then
        table.remove(action_queue, 1)
        cmd = '/item "' .. action.name .. '" <me>'
        delay = ITEM_DELAY
    elseif action.type == 'get_item' then
        table.remove(action_queue, 1)
        local success = ensure_item_in_inventory(action.item_id)
        if not success then
            chat('Failed to retrieve ' .. (action.name or 'item') .. ' from bags.')
        end
        coroutine.schedule(process_next_action, ITEM_MOVE_DELAY)
        return
    elseif action.type == 'cancel' then
        table.remove(action_queue, 1)
        local player = windower.ffxi.get_player()
        if player then
            for _, buff_id in ipairs(player.buffs) do
                if res.buffs[buff_id] and res.buffs[buff_id].name == action.name then
                    windower.ffxi.cancel_buff(buff_id)
                    break
                end
            end
        end
        coroutine.schedule(process_next_action, 0.5)
        return
    end

    windower.send_command('input ' .. cmd)
    coroutine.schedule(process_next_action, delay)
end

local function enqueue_actions(actions)
    for _, a in ipairs(actions) do
        action_queue[#action_queue + 1] = a
    end
    if not queue_active then
        queue_active = true
        process_next_action()
    end
end

-------------------------------------------------------------------------------
-- Serialization for EXEC IPC messages
-------------------------------------------------------------------------------

local function serialize_action(action)
    local t = action.type or '_'
    local n = action.name or '_'
    local tgt = action.target or '_'
    local iid = action.item_id and tostring(action.item_id) or '_'
    return t .. ':' .. n .. ':' .. tgt .. ':' .. iid
end

local function deserialize_action(str)
    local parts = {}
    for part in str:gmatch('[^:]+') do
        parts[#parts + 1] = part
    end
    return {
        type = parts[1] ~= '_' and parts[1] or nil,
        name = parts[2] ~= '_' and parts[2] or nil,
        target = parts[3] ~= '_' and parts[3] or nil,
        item_id = parts[4] ~= '_' and tonumber(parts[4]) or nil,
    }
end

local function serialize_action_list(actions)
    local strs = {}
    for _, a in ipairs(actions) do
        strs[#strs + 1] = serialize_action(a)
    end
    return table.concat(strs, ';')
end

local function deserialize_action_list(str)
    local actions = {}
    for part in str:gmatch('[^;]+') do
        actions[#actions + 1] = deserialize_action(part)
    end
    return actions
end

-------------------------------------------------------------------------------
-- Scholar Path Builder
-------------------------------------------------------------------------------

local function build_scholar_actions(state)
    local actions = {}
    local buffs = state.buffs or {}

    if not buffs[BUFF_LIGHT_ARTS] and not buffs[BUFF_ADDENDUM_WHITE] then
        actions[#actions + 1] = {type = 'ja', name = 'Light Arts', target = '<me>'}
    end

    if not buffs[BUFF_ACCESSION] then
        actions[#actions + 1] = {type = 'ja', name = 'Accession', target = '<me>'}
    end

    actions[#actions + 1] = {type = 'ma', name = 'Sneak', target = '<me>'}

    actions[#actions + 1] = {type = 'ja', name = 'Accession', target = '<me>'}

    actions[#actions + 1] = {type = 'ma', name = 'Invisible', target = '<me>'}

    return actions
end

-------------------------------------------------------------------------------
-- Multi-Caster Round Robin Builder
-------------------------------------------------------------------------------

local function build_multicaster_actions(casters, non_casters)
    local plans = {}
    for _, c in ipairs(casters) do
        plans[c.name] = {}
    end

    for _, nc in ipairs(non_casters) do
        plans[nc.name] = {}
    end

    for _, caster in ipairs(casters) do
        plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Sneak', target = '<me>'}
    end

    local caster_count = #casters
    for i, nc in ipairs(non_casters) do
        local caster = casters[((i - 1) % caster_count) + 1]
        plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Sneak', target = nc.name}
    end

    for i, nc in ipairs(non_casters) do
        local caster = casters[((i - 1) % caster_count) + 1]
        plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Invisible', target = nc.name}
    end

    for _, caster in ipairs(casters) do
        plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Invisible', target = '<me>'}
    end

    return plans
end

-------------------------------------------------------------------------------
-- Single Caster Builder
-------------------------------------------------------------------------------

local function build_single_caster_solo(caster, others)
    local plans = {}
    plans[caster.name] = {}

    for _, other in ipairs(others) do
        plans[other.name] = {}
    end

    plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Sneak', target = '<me>'}

    for _, other in ipairs(others) do
        plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Sneak', target = other.name}
    end

    for _, other in ipairs(others) do
        plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Invisible', target = other.name}
    end

    plans[caster.name][#plans[caster.name] + 1] = {type = 'ma', name = 'Invisible', target = '<me>'}

    return plans
end

-------------------------------------------------------------------------------
-- Spectral Jig Builder (DNC self-sneak+invis)
-------------------------------------------------------------------------------

local function build_spectral_jig_actions(state)
    local actions = {}
    actions[#actions + 1] = {type = 'ja', name = 'Spectral Jig', target = '<me>'}
    return actions
end

-------------------------------------------------------------------------------
-- Stratagem Charge Check
-------------------------------------------------------------------------------

local function get_stratagem_charges()
    local player = windower.ffxi.get_player()
    if not player then return 0 end

    local sch_level = 0
    if player.main_job == 'SCH' then
        sch_level = player.main_job_level
    elseif player.sub_job == 'SCH' then
        sch_level = player.sub_job_level
    end

    if sch_level == 0 then return 0 end

    local recasts = windower.ffxi.get_ability_recasts()
    local strat_recast = recasts[231] or 0
    local max_strats = math.floor((sch_level + 10) / 20)
    local recharge_time = 4 * 60
    local current = math.floor(max_strats - max_strats * strat_recast / recharge_time)

    return math.max(0, current)
end

-------------------------------------------------------------------------------
-- Plan Builder & Dispatcher
-------------------------------------------------------------------------------

local function get_party_names()
    local party = windower.ffxi.get_party()
    local names = {}
    local my_zone = windower.ffxi.get_info().zone
    for i = 0, 5 do
        local member = party['p' .. i]
        if member and member.name and member.zone == my_zone then
            names[#names + 1] = member.name
        end
    end
    return names
end

local function dispatch_plans(plans)
    local player = windower.ffxi.get_player()
    if not player then return end

    for name, actions in pairs(plans) do
        local full_actions = {}
        full_actions[#full_actions + 1] = {type = 'cancel', name = 'Sneak'}
        full_actions[#full_actions + 1] = {type = 'cancel', name = 'Invisible'}
        for _, a in ipairs(actions) do
            full_actions[#full_actions + 1] = a
        end

        if name == player.name then
            enqueue_actions(full_actions)
        else
            local msg = 'PWAT:EXEC|' .. name .. '|' .. serialize_action_list(full_actions)
            windower.send_ipc_message(msg)
        end
    end
end

local function execute_plan()
    local player = windower.ffxi.get_player()
    if not player then
        chat('Not logged in.')
        return
    end

    local party_names = get_party_names()
    if #party_names == 0 then
        chat('No party members detected in zone.')
        return
    end

    local members = {}
    for _, name in ipairs(party_names) do
        if party_cache[name] then
            members[#members + 1] = party_cache[name]
        end
    end

    if #members == 0 then
        chat('No cached data for party members. Waiting for sync...')
        broadcast_state()
        windower.send_ipc_message('PWAT:QUERY')
        return
    end

    local sch_member = nil
    for _, m in ipairs(members) do
        if m.has_accession and m.can_cast_sneak and m.can_cast_invis then
            sch_member = m
            break
        end
    end

    if sch_member then
        local charges = 0
        if sch_member.name == player.name then
            charges = get_stratagem_charges()
        end

        local needed = 2
        local buffs = sch_member.buffs or {}
        if buffs[BUFF_ACCESSION] then needed = needed - 1 end

        if sch_member.name == player.name and charges < needed then
            chat('Scholar lacks stratagem charges (' .. charges .. '/' .. needed .. '). Falling through to next strategy.')
        else
            chat('Using Scholar AoE strategy via ' .. sch_member.name .. '.')
            local actions = build_scholar_actions(sch_member)
            local plans = {[sch_member.name] = actions}
            for _, m in ipairs(members) do
                if m.name ~= sch_member.name then
                    plans[m.name] = {}
                end
            end
            dispatch_plans(plans)
            return
        end
    end

    local jig_plans = {}
    local remaining_members = {}
    for _, m in ipairs(members) do
        if settings.useJig and m.has_spectral_jig and not (m.can_cast_sneak and m.can_cast_invis) then
            jig_plans[m.name] = build_spectral_jig_actions(m)
        else
            remaining_members[#remaining_members + 1] = m
        end
    end

    local casters = {}
    local non_casters = {}
    for _, m in ipairs(remaining_members) do
        if m.can_cast_sneak and m.can_cast_invis then
            casters[#casters + 1] = m
        else
            non_casters[#non_casters + 1] = m
        end
    end

    local item_plans = {}
    local cast_targets = {}
    if use_items then
        for _, nc in ipairs(non_casters) do
            local has_oil = (nc.oil_count or 0) > 0
            local has_powder = (nc.powder_count or 0) > 0
            if has_oil and has_powder then
                item_plans[nc.name] = {
                    {type = 'get_item', name = 'Silent Oil', item_id = SILENT_OIL_ID},
                    {type = 'item', name = 'Silent Oil'},
                    {type = 'get_item', name = 'Prism Powder', item_id = PRISM_POWDER_ID},
                    {type = 'item', name = 'Prism Powder'},
                }
            else
                cast_targets[#cast_targets + 1] = nc
            end
        end
    else
        cast_targets = non_casters
    end

    if #casters >= 2 then
        chat('Using multi-caster round robin strategy (' .. #casters .. ' casters).')
        local plans = build_multicaster_actions(casters, cast_targets)
        for name, acts in pairs(item_plans) do plans[name] = acts end
        for name, acts in pairs(jig_plans) do plans[name] = acts end
        dispatch_plans(plans)
        return
    end

    if #casters == 1 then
        local caster = casters[1]
        chat('Using single caster strategy via ' .. caster.name .. '.')
        local plans = build_single_caster_solo(caster, cast_targets)
        for name, acts in pairs(item_plans) do plans[name] = acts end
        for name, acts in pairs(jig_plans) do plans[name] = acts end
        dispatch_plans(plans)
        return
    end

    if next(item_plans) or next(jig_plans) then
        if next(item_plans) then
            chat('No casters available. Using items for those who have them.')
        end
        local plans = {}
        for name, acts in pairs(item_plans) do plans[name] = acts end
        for name, acts in pairs(jig_plans) do plans[name] = acts end
        for _, nc in ipairs(cast_targets) do
            chat(nc.name .. ' has no items and no caster available.')
            plans[nc.name] = {}
        end
        dispatch_plans(plans)
        return
    end

    chat('No casters and item usage is disabled. Cannot sneak/invis the party.')
end

-------------------------------------------------------------------------------
-- IPC Message Handler
-------------------------------------------------------------------------------

windower.register_event('ipc message', function(msg)
    if not windower.ffxi.get_info().logged_in then return end

    if msg:sub(1, 10) == 'PWAT:STATE' then
        local state = deserialize_state(msg)
        if state then
            party_cache[state.name] = state
        end

    elseif msg == 'PWAT:QUERY' then
        broadcast_state()

    elseif msg:sub(1, 9) == 'PWAT:EXEC' then
        local player = windower.ffxi.get_player()
        if not player then return end

        local pipe1 = msg:find('|', 11)
        if not pipe1 then return end

        local target_name = msg:sub(11, pipe1 - 1)
        if target_name ~= player.name then return end

        local action_str = msg:sub(pipe1 + 1)
        local actions = deserialize_action_list(action_str)
        chat('Received ' .. #actions .. ' action(s) to execute.')
        enqueue_actions(actions)

    elseif msg == 'PWAT:CANCEL' then
        clear_queue()
        chat('Actions cancelled.')
    end
end)

-------------------------------------------------------------------------------
-- Broadcast Triggers
-------------------------------------------------------------------------------

windower.register_event('load', function()
    if windower.ffxi.get_info().logged_in then
        coroutine.schedule(broadcast_state, 2)
    end
end)

windower.register_event('login', function()
    coroutine.schedule(broadcast_state, 3)
end)

windower.register_event('job change', function()
    coroutine.schedule(broadcast_state, 1)
end)

windower.register_event('zone change', function()
    clear_queue()
    coroutine.schedule(broadcast_state, 5)
end)

windower.register_event('logout', 'unload', function()
    clear_queue()
end)

local buff_broadcast_scheduled = false
windower.register_event('gain buff', 'lose buff', function(id)
    if not buff_broadcast_scheduled then
        buff_broadcast_scheduled = true
        coroutine.schedule(function()
            buff_broadcast_scheduled = false
            broadcast_state()
        end, 0.5)
    end
end)

-------------------------------------------------------------------------------
-- Command Handler
-------------------------------------------------------------------------------

windower.register_event('addon command', function(command, ...)
    if not windower.ffxi.get_info().logged_in then
        chat('Not logged in.')
        return
    end

    command = command and command:lower() or ''
    local args = {...}

    if command == '' or command == 'go' or command == 'run' then
        chat('Querying party state...')
        broadcast_state()
        windower.send_ipc_message('PWAT:QUERY')
        coroutine.schedule(execute_plan, 1)

    elseif command == 'items' then
        if args[1] then
            local val = args[1]:lower()
            if val == 'on' or val == 'true' then
                use_items = true
            elseif val == 'off' or val == 'false' then
                use_items = false
            end
        else
            use_items = not use_items
        end
        chat('Item usage: ' .. (use_items and 'ON' or 'OFF'))

    elseif command == 'jig' then
        if args[1] then
            local val = args[1]:lower()
            if val == 'on' or val == 'true' then
                settings.useJig = true
            elseif val == 'off' or val == 'false' then
                settings.useJig = false
            end
        else
            settings.useJig = not settings.useJig
        end
        settings:save()
        chat('Spectral Jig usage: ' .. (settings.useJig and 'ON' or 'OFF'))

    elseif command == 'status' then
        chat('--- Party Cache ---')
        local party_names = get_party_names()
        for _, name in ipairs(party_names) do
            local s = party_cache[name]
            if s then
                local info = name .. ' [' .. s.main_job
                if s.sub_job then info = info .. '/' .. s.sub_job end
                info = info .. '] Snk:' .. (s.can_cast_sneak and 'Y' or 'N')
                info = info .. ' Inv:' .. (s.can_cast_invis and 'Y' or 'N')
                info = info .. ' LA:' .. (s.has_light_arts and 'Y' or 'N')
                info = info .. ' Acc:' .. (s.has_accession and 'Y' or 'N')
                info = info .. ' Jig:' .. (s.has_spectral_jig and 'Y' or 'N')
                info = info .. ' Oil:' .. (s.oil_count or 0)
                info = info .. ' Pow:' .. (s.powder_count or 0)
                chat(info)
            else
                chat(name .. ' [no data - addon may not be loaded]')
            end
        end
        chat('Item usage: ' .. (use_items and 'ON' or 'OFF'))
        chat('Spectral Jig: ' .. (settings.useJig and 'ON' or 'OFF'))

    elseif command == 'cancel' then
        clear_queue()
        windower.send_ipc_message('PWAT:CANCEL')
        chat('Cancelled all actions on all characters.')

    elseif command == 'help' then
        chat('PassWithoutATrace v' .. _addon.version)
        chat('Usage:')
        chat('  //pwat          - Sneak+Invis the whole party')
        chat('  //pwat items [on|off] - Toggle item usage (current: ' .. (use_items and 'ON' or 'OFF') .. ')')
        chat('  //pwat jig [on|off]   - Toggle Spectral Jig (current: ' .. (settings.useJig and 'ON' or 'OFF') .. ')')
        chat('  //pwat status   - Show party cache')
        chat('  //pwat cancel   - Cancel all pending actions')
        chat('  //pwat help     - Show this help')

    else
        chat('Unknown command: ' .. command .. '. Use //pwat help for usage.')
    end
end)
