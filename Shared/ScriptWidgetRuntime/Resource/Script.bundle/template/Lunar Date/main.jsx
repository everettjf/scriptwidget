
//
// ScriptWidget
// https://atomsprout.com/scriptwidget
//
//

var getLunarData = (function () {
    //公历农历转换
    var calendar = {
        lunarInfo: [0x04bd8, 0x04ae0, 0x0a570, 0x054d5, 0x0d260, 0x0d950, 0x16554, 0x056a0, 0x09ad0, 0x055d2,
            0x04ae0, 0x0a5b6, 0x0a4d0, 0x0d250, 0x1d255, 0x0b540, 0x0d6a0, 0x0ada2, 0x095b0, 0x14977,
            0x04970, 0x0a4b0, 0x0b4b5, 0x06a50, 0x06d40, 0x1ab54, 0x02b60, 0x09570, 0x052f2, 0x04970,
            0x06566, 0x0d4a0, 0x0ea50, 0x06e95, 0x05ad0, 0x02b60, 0x186e3, 0x092e0, 0x1c8d7, 0x0c950,
            0x0d4a0, 0x1d8a6, 0x0b550, 0x056a0, 0x1a5b4, 0x025d0, 0x092d0, 0x0d2b2, 0x0a950, 0x0b557,
            0x06ca0, 0x0b550, 0x15355, 0x04da0, 0x0a5b0, 0x14573, 0x052b0, 0x0a9a8, 0x0e950, 0x06aa0,
            0x0aea6, 0x0ab50, 0x04b60, 0x0aae4, 0x0a570, 0x05260, 0x0f263, 0x0d950, 0x05b57, 0x056a0,
            0x096d0, 0x04dd5, 0x04ad0, 0x0a4d0, 0x0d4d4, 0x0d250, 0x0d558, 0x0b540, 0x0b6a0, 0x195a6,
            0x095b0, 0x049b0, 0x0a974, 0x0a4b0, 0x0b27a, 0x06a50, 0x06d40, 0x0af46, 0x0ab60, 0x09570,
            0x04af5, 0x04970, 0x064b0, 0x074a3, 0x0ea50, 0x06b58, 0x055c0, 0x0ab60, 0x096d5, 0x092e0,
            0x0c960, 0x0d954, 0x0d4a0, 0x0da50, 0x07552, 0x056a0, 0x0abb7, 0x025d0, 0x092d0, 0x0cab5,
            0x0a950, 0x0b4a0, 0x0baa4, 0x0ad50, 0x055d9, 0x04ba0, 0x0a5b0, 0x15176, 0x052b0, 0x0a930,
            0x07954, 0x06aa0, 0x0ad50, 0x05b52, 0x04b60, 0x0a6e6, 0x0a4e0, 0x0d260, 0x0ea65, 0x0d530,
            0x05aa0, 0x076a3, 0x096d0, 0x04bd7, 0x04ad0, 0x0a4d0, 0x1d0b6, 0x0d250, 0x0d520, 0x0dd45,
            0x0b5a0, 0x056d0, 0x055b2, 0x049b0, 0x0a577, 0x0a4b0, 0x0aa50, 0x1b255, 0x06d20, 0x0ada0,
            0x14b63, 0x09370, 0x049f8, 0x04970, 0x064b0, 0x168a6, 0x0ea50, 0x06b20, 0x1a6c4, 0x0aae0,
            0x0a2e0, 0x0d2e3, 0x0c960, 0x0d557, 0x0d4a0, 0x0da50, 0x05d55, 0x056a0, 0x0a6d0, 0x055d4,
            0x052d0, 0x0a9b8, 0x0a950, 0x0b4a0, 0x0b6a6, 0x0ad50, 0x055a0, 0x0aba4, 0x0a5b0, 0x052b0,
            0x0b273, 0x06930, 0x07337, 0x06aa0, 0x0ad50, 0x14b55, 0x04b60, 0x0a570, 0x054e4, 0x0d160,
            0x0e968, 0x0d520, 0x0daa0, 0x16aa6, 0x056d0, 0x04ae0, 0x0a9d4, 0x0a2d0, 0x0d150, 0x0f252,
            0x0d520],
        solarMonth: [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31],
        Gan: ["\u7532", "\u4e59", "\u4e19", "\u4e01", "\u620a", "\u5df1", "\u5e9a", "\u8f9b", "\u58ec", "\u7678"],
        Zhi: ["\u5b50", "\u4e11", "\u5bc5", "\u536f", "\u8fb0", "\u5df3", "\u5348", "\u672a", "\u7533", "\u9149", "\u620c", "\u4ea5"],
        Animals: ["\u9f20", "\u725b", "\u864e", "\u5154", "\u9f99", "\u86c7", "\u9a6c", "\u7f8a", "\u7334", "\u9e21", "\u72d7", "\u732a"],
        solarTerm: ["\u5c0f\u5bd2", "\u5927\u5bd2", "\u7acb\u6625", "\u96e8\u6c34", "\u60ca\u86f0", "\u6625\u5206", "\u6e05\u660e", "\u8c37\u96e8", "\u7acb\u590f", "\u5c0f\u6ee1", "\u8292\u79cd", "\u590f\u81f3", "\u5c0f\u6691", "\u5927\u6691", "\u7acb\u79cb", "\u5904\u6691", "\u767d\u9732", "\u79cb\u5206", "\u5bd2\u9732", "\u971c\u964d", "\u7acb\u51ac", "\u5c0f\u96ea", "\u5927\u96ea", "\u51ac\u81f3"],
        sTermInfo: ['9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e', '97bcf97c3598082c95f8c965cc920f',
            '97bd0b06bdb0722c965ce1cfcc920f', 'b027097bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
            '97bcf97c359801ec95f8c965cc920f', '97bd0b06bdb0722c965ce1cfcc920f', 'b027097bd097c36b0b6fc9274c91aa',
            '97b6b97bd19801ec9210c965cc920e', '97bcf97c359801ec95f8c965cc920f', '97bd0b06bdb0722c965ce1cfcc920f',
            'b027097bd097c36b0b6fc9274c91aa', '9778397bd19801ec9210c965cc920e', '97b6b97bd19801ec95f8c965cc920f',
            '97bd09801d98082c95f8e1cfcc920f', '97bd097bd097c36b0b6fc9210c8dc2', '9778397bd197c36c9210c9274c91aa',
            '97b6b97bd19801ec95f8c965cc920e', '97bd09801d98082c95f8e1cfcc920f', '97bd097bd097c36b0b6fc9210c8dc2',
            '9778397bd097c36c9210c9274c91aa', '97b6b97bd19801ec95f8c965cc920e', '97bcf97c3598082c95f8e1cfcc920f',
            '97bd097bd097c36b0b6fc9210c8dc2', '9778397bd097c36c9210c9274c91aa', '97b6b97bd19801ec9210c965cc920e',
            '97bcf97c3598082c95f8c965cc920f', '97bd097bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
            '97b6b97bd19801ec9210c965cc920e', '97bcf97c3598082c95f8c965cc920f', '97bd097bd097c35b0b6fc920fb0722',
            '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e', '97bcf97c359801ec95f8c965cc920f',
            '97bd097bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
            '97bcf97c359801ec95f8c965cc920f', '97bd097bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
            '97b6b97bd19801ec9210c965cc920e', '97bcf97c359801ec95f8c965cc920f', '97bd097bd07f595b0b6fc920fb0722',
            '9778397bd097c36b0b6fc9210c8dc2', '9778397bd19801ec9210c9274c920e', '97b6b97bd19801ec95f8c965cc920f',
            '97bd07f5307f595b0b0bc920fb0722', '7f0e397bd097c36b0b6fc9210c8dc2', '9778397bd097c36c9210c9274c920e',
            '97b6b97bd19801ec95f8c965cc920f', '97bd07f5307f595b0b0bc920fb0722', '7f0e397bd097c36b0b6fc9210c8dc2',
            '9778397bd097c36c9210c9274c91aa', '97b6b97bd19801ec9210c965cc920e', '97bd07f1487f595b0b0bc920fb0722',
            '7f0e397bd097c36b0b6fc9210c8dc2', '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
            '97bcf7f1487f595b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
            '97b6b97bd19801ec9210c965cc920e', '97bcf7f1487f595b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
            '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e', '97bcf7f1487f531b0b0bb0b6fb0722',
            '7f0e397bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa', '97b6b97bd19801ec9210c965cc920e',
            '97bcf7f1487f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
            '97b6b97bd19801ec9210c9274c920e', '97bcf7f0e47f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
            '9778397bd097c36b0b6fc9210c91aa', '97b6b97bd197c36c9210c9274c920e', '97bcf7f0e47f531b0b0bb0b6fb0722',
            '7f0e397bd07f595b0b0bc920fb0722', '9778397bd097c36b0b6fc9210c8dc2', '9778397bd097c36c9210c9274c920e',
            '97b6b7f0e47f531b0723b0b6fb0722', '7f0e37f5307f595b0b0bc920fb0722', '7f0e397bd097c36b0b6fc9210c8dc2',
            '9778397bd097c36b0b70c9274c91aa', '97b6b7f0e47f531b0723b0b6fb0721', '7f0e37f1487f595b0b0bb0b6fb0722',
            '7f0e397bd097c35b0b6fc9210c8dc2', '9778397bd097c36b0b6fc9274c91aa', '97b6b7f0e47f531b0723b0b6fb0721',
            '7f0e27f1487f595b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
            '97b6b7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
            '9778397bd097c36b0b6fc9274c91aa', '97b6b7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722',
            '7f0e397bd097c35b0b6fc920fb0722', '9778397bd097c36b0b6fc9274c91aa', '97b6b7f0e47f531b0723b0b6fb0721',
            '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722', '9778397bd097c36b0b6fc9274c91aa',
            '97b6b7f0e47f531b0723b0787b0721', '7f0e27f0e47f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
            '9778397bd097c36b0b6fc9210c91aa', '97b6b7f0e47f149b0723b0787b0721', '7f0e27f0e47f531b0723b0b6fb0722',
            '7f0e397bd07f595b0b0bc920fb0722', '9778397bd097c36b0b6fc9210c8dc2', '977837f0e37f149b0723b0787b0721',
            '7f07e7f0e47f531b0723b0b6fb0722', '7f0e37f5307f595b0b0bc920fb0722', '7f0e397bd097c35b0b6fc9210c8dc2',
            '977837f0e37f14998082b0787b0721', '7f07e7f0e47f531b0723b0b6fb0721', '7f0e37f1487f595b0b0bb0b6fb0722',
            '7f0e397bd097c35b0b6fc9210c8dc2', '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
            '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722', '977837f0e37f14998082b0787b06bd',
            '7f07e7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd097c35b0b6fc920fb0722',
            '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722',
            '7f0e397bd07f595b0b0bc920fb0722', '977837f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
            '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722', '977837f0e37f14998082b0787b06bd',
            '7f07e7f0e47f149b0723b0787b0721', '7f0e27f0e47f531b0b0bb0b6fb0722', '7f0e397bd07f595b0b0bc920fb0722',
            '977837f0e37f14998082b0723b06bd', '7f07e7f0e37f149b0723b0787b0721', '7f0e27f0e47f531b0723b0b6fb0722',
            '7f0e397bd07f595b0b0bc920fb0722', '977837f0e37f14898082b0723b02d5', '7ec967f0e37f14998082b0787b0721',
            '7f07e7f0e47f531b0723b0b6fb0722', '7f0e37f1487f595b0b0bb0b6fb0722', '7f0e37f0e37f14898082b0723b02d5',
            '7ec967f0e37f14998082b0787b0721', '7f07e7f0e47f531b0723b0b6fb0722', '7f0e37f1487f531b0b0bb0b6fb0722',
            '7f0e37f0e37f14898082b0723b02d5', '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
            '7f0e37f1487f531b0b0bb0b6fb0722', '7f0e37f0e37f14898082b072297c35', '7ec967f0e37f14998082b0787b06bd',
            '7f07e7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e37f0e37f14898082b072297c35',
            '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722',
            '7f0e37f0e366aa89801eb072297c35', '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f149b0723b0787b0721',
            '7f0e27f1487f531b0b0bb0b6fb0722', '7f0e37f0e366aa89801eb072297c35', '7ec967f0e37f14998082b0723b06bd',
            '7f07e7f0e47f149b0723b0787b0721', '7f0e27f0e47f531b0723b0b6fb0722', '7f0e37f0e366aa89801eb072297c35',
            '7ec967f0e37f14998082b0723b06bd', '7f07e7f0e37f14998083b0787b0721', '7f0e27f0e47f531b0723b0b6fb0722',
            '7f0e37f0e366aa89801eb072297c35', '7ec967f0e37f14898082b0723b02d5', '7f07e7f0e37f14998082b0787b0721',
            '7f07e7f0e47f531b0723b0b6fb0722', '7f0e36665b66aa89801e9808297c35', '665f67f0e37f14898082b0723b02d5',
            '7ec967f0e37f14998082b0787b0721', '7f07e7f0e47f531b0723b0b6fb0722', '7f0e36665b66a449801e9808297c35',
            '665f67f0e37f14898082b0723b02d5', '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721',
            '7f0e36665b66a449801e9808297c35', '665f67f0e37f14898082b072297c35', '7ec967f0e37f14998082b0787b06bd',
            '7f07e7f0e47f531b0723b0b6fb0721', '7f0e26665b66a449801e9808297c35', '665f67f0e37f1489801eb072297c35',
            '7ec967f0e37f14998082b0787b06bd', '7f07e7f0e47f531b0723b0b6fb0721', '7f0e27f1487f531b0b0bb0b6fb0722'],
        nStr1: ["\u65e5", "\u4e00", "\u4e8c", "\u4e09", "\u56db", "\u4e94", "\u516d", "\u4e03", "\u516b", "\u4e5d", "\u5341"],
        nStr2: ["\u521d", "\u5341", "\u5eff", "\u5345"],
        nStr3: ["\u6b63", "\u4e8c", "\u4e09", "\u56db", "\u4e94", "\u516d", "\u4e03", "\u516b", "\u4e5d", "\u5341", "\u51ac", "\u814a"],
        lYearDays: function (y) {
            var i, sum = 348;
            for (i = 0x8000; i > 0x8; i >>= 1) { sum += (calendar.lunarInfo[y - 1900] & i) ? 1 : 0; }
            return (sum + calendar.leapDays(y));
        },
        leapMonth: function (y) {
            return (calendar.lunarInfo[y - 1900] & 0xf);
        },
        leapDays: function (y) {
            if (calendar.leapMonth(y)) {
                return ((calendar.lunarInfo[y - 1900] & 0x10000) ? 30 : 29);
            }
            return (0);
        },
        monthDays: function (y, m) {
            if (m > 12 || m < 1) { return -1 }
            return ((calendar.lunarInfo[y - 1900] & (0x10000 >> m)) ? 30 : 29);
        },
        solarDays: function (y, m) {
            if (m > 12 || m < 1) { return -1 }
            var ms = m - 1;
            if (ms == 1) {
                return (((y % 4 == 0) && (y % 100 != 0) || (y % 400 == 0)) ? 29 : 28);
            } else {
                return (calendar.solarMonth[ms]);
            }
        },
        toGanZhi: function (offset) {
            return (calendar.Gan[offset % 10] + calendar.Zhi[offset % 12]);
        },
        getTerm: function (y, n) {
            if (y < 1900 || y > 2100) { return -1; }
            if (n < 1 || n > 24) { return -1; }
            var _table = calendar.sTermInfo[y - 1900];
            var _info = [
                parseInt('0x' + _table.substr(0, 5)).toString(),
                parseInt('0x' + _table.substr(5, 5)).toString(),
                parseInt('0x' + _table.substr(10, 5)).toString(),
                parseInt('0x' + _table.substr(15, 5)).toString(),
                parseInt('0x' + _table.substr(20, 5)).toString(),
                parseInt('0x' + _table.substr(25, 5)).toString()
            ];
            var _calday = [
                _info[0].substr(0, 1),
                _info[0].substr(1, 2),
                _info[0].substr(3, 1),
                _info[0].substr(4, 2),
                _info[1].substr(0, 1),
                _info[1].substr(1, 2),
                _info[1].substr(3, 1),
                _info[1].substr(4, 2),
                _info[2].substr(0, 1),
                _info[2].substr(1, 2),
                _info[2].substr(3, 1),
                _info[2].substr(4, 2),
                _info[3].substr(0, 1),
                _info[3].substr(1, 2),
                _info[3].substr(3, 1),
                _info[3].substr(4, 2),
                _info[4].substr(0, 1),
                _info[4].substr(1, 2),
                _info[4].substr(3, 1),
                _info[4].substr(4, 2),
                _info[5].substr(0, 1),
                _info[5].substr(1, 2),
                _info[5].substr(3, 1),
                _info[5].substr(4, 2),
            ];
            return parseInt(_calday[n - 1]);
        },
        toChinaMonth: function (m) {
            if (m > 12 || m < 1) { return -1 }
            var s = calendar.nStr3[m - 1];
            s += "\u6708";
            return s;
        },
        toChinaDay: function (d) {
            var s;
            switch (d) {
                case 10:
                    s = '\u521d\u5341';
                    break;
                case 20:
                    s = '\u4e8c\u5341';
                    break;
                case 30:
                    s = '\u4e09\u5341';
                    break;
                default:
                    s = calendar.nStr2[Math.floor(d / 10)];
                    s += calendar.nStr1[d % 10];
            }
            return (s);
        },
        getAnimal: function (y) {
            return calendar.Animals[(y - 4) % 12]
        },
        solar2lunar: function (y, m, d) {
            if (y < 1900 || y > 2100) { return -1; }
            if (y == 1900 && m == 1 && d < 31) { return -1; }
            if (!y) {
                var objDate = new Date();
            } else {
                var objDate = new Date(y, parseInt(m) - 1, d)
            }
            var i, leap = 0, temp = 0;
            var y = objDate.getFullYear(), m = objDate.getMonth() + 1, d = objDate.getDate();
            var offset = (Date.UTC(objDate.getFullYear(), objDate.getMonth(), objDate.getDate()) - Date.UTC(1900, 0, 31)) / 86400000;
            for (i = 1900; i < 2101 && offset > 0; i++) { temp = calendar.lYearDays(i); offset -= temp; }
            if (offset < 0) { offset += temp; i--; }
            var isTodayObj = new Date(), isToday = false;
            if (isTodayObj.getFullYear() == y && isTodayObj.getMonth() + 1 == m && isTodayObj.getDate() == d) {
                isToday = true;
            }
            var nWeek = objDate.getDay(), cWeek = calendar.nStr1[nWeek];
            if (nWeek == 0) { nWeek = 7; }
            var year = i;
            var leap = calendar.leapMonth(i);
            var isLeap = false;
            for (i = 1; i < 13 && offset > 0; i++) {
                if (leap > 0 && i == (leap + 1) && isLeap == false) {
                    --i;
                    isLeap = true; temp = calendar.leapDays(year);
                } else {
                    temp = calendar.monthDays(year, i);
                }
                if (isLeap == true && i == (leap + 1)) { isLeap = false; }
                offset -= temp;
            }
            if (offset == 0 && leap > 0 && i == leap + 1) {
                if (isLeap) {
                    isLeap = false;
                } else {
                    isLeap = true; --i;
                }
            }
            if (offset < 0) { offset += temp; --i; }
            var month = i;
            var day = offset + 1;
            var sm = m - 1;
            var term3 = calendar.getTerm(year, 3);
            var gzY = calendar.toGanZhi(year - 4);
            gzY = calendar.toGanZhi(year - 4); //modify
            var firstNode = calendar.getTerm(y, (m * 2 - 1));
            var secondNode = calendar.getTerm(y, (m * 2));
            var gzM = calendar.toGanZhi((y - 1900) * 12 + m + 11);
            if (d >= firstNode) {
                gzM = calendar.toGanZhi((y - 1900) * 12 + m + 12);
            }
            var isTerm = false;
            var Term = null;
            if (firstNode == d) {
                isTerm = true;
                Term = calendar.solarTerm[m * 2 - 2];
            }
            if (secondNode == d) {
                isTerm = true;
                Term = calendar.solarTerm[m * 2 - 1];
            }
            var dayCyclical = Date.UTC(y, sm, 1, 0, 0, 0, 0) / 86400000 + 25567 + 10;
            var gzD = calendar.toGanZhi(dayCyclical + d - 1);
            return { 'lYear': year, 'lMonth': month, 'lDay': day, 'Animal': calendar.getAnimal(year), 'IMonthCn': (isLeap ? "\u95f0" : '') + calendar.toChinaMonth(month), 'IDayCn': calendar.toChinaDay(day), 'cYear': y, 'cMonth': m, 'cDay': d, 'gzYear': gzY, 'gzMonth': gzM, 'gzDay': gzD, 'isToday': isToday, 'isLeap': isLeap, 'nWeek': nWeek, 'ncWeek': "\u661f\u671f" + cWeek, 'isTerm': isTerm, 'Term': Term };
        }
    };
    //公历节日
    var _festival1 = {
        '0101': '元旦节',
        '0202': '世界湿地日',
        '0210': '国际气象节',
        '0214': '情人节',
        '0301': '国际海豹日',
        '0303': '全国爱耳日',
        '0305': '学雷锋纪念日',
        '0308': '妇女节',
        '0312': '植树节',
        '0314': '国际警察日',
        '0315': '消费者权益日',
        '0317': '中国国医节 国际航海日',
        '0321': '世界森林日 消除种族歧视国际日 世界儿歌日',
        '0322': '世界水日',
        '0323': '世界气象日',
        '0324': '世界防治结核病日',
        '0325': '全国中小学生安全教育日',
        '0401': '愚人节',
        '0407': '世界卫生日',
        '0422': '世界地球日',
        '0423': '世界图书和版权日',
        '0424': '亚非新闻工作者日',
        '0501': '劳动节',
        '0504': '青年节',
        '0515': '防治碘缺乏病日',
        '0508': '世界红十字日',
        '0512': '国际护士节',
        '0515': '国际家庭日',
        '0517': '世界电信日',
        '0518': '国际博物馆日',
        '0520': '全国学生营养日',
        '0522': '国际生物多样性日',
        '0531': '世界无烟日',
        '0601': '国际儿童节 世界牛奶日',
        '0605': '世界环境日',
        '0606': '全国爱眼日',
        '0617': '防治荒漠化和干旱日',
        '0623': '国际奥林匹克日',
        '0625': '全国土地日',
        '0626': '国际禁毒日',
        '0701': '建党节 香港回归纪念日',
        '0702': '国际体育记者日',
        '0711': '世界人口日 航海日',
        '0801': '建军节',
        '0808': '中国男子节(爸爸节)',
        '0903': '抗日战争胜利纪念日',
        '0908': '国际扫盲日 国际新闻工作者日',
        '0910': '教师节',
        '0916': '国际臭氧层保护日',
        '0918': '九·一八事变纪念日',
        '0920': '国际爱牙日',
        '0927': '世界旅游日',
        '1001': '国庆节 国际音乐日 国际老人节',
        '1002': '国际非暴力日 国际和平与民主自由斗争日',
        '1004': '世界动物日',
        '1006': '老人节',
        '1008': '全国高血压日',
        '1005': '国际教师节',
        '1009': '世界邮政日',
        '1010': '辛亥革命纪念日 世界精神卫生日',
        '1013': '世界保健日 国际减灾日',
        '1014': '世界标准日',
        '1015': '国际盲人节(白手杖节)',
        '1016': '世界粮食日',
        '1017': '世界消除贫困日',
        '1022': '世界传统医药日',
        '1024': '联合国日 世界发展信息日',
        '1031': '世界勤俭日',
        '1107': '十月社会主义革命纪念日',
        '1108': '中国记者日',
        '1109': '全国消防安全宣传教育日',
        '1110': '世界青年节',
        '1111': '国际科学与和平周(本日所属的一周)',
        '1112': '孙中山诞辰纪念日',
        '1114': '联合国糖尿病日',
        '1117': '国际大学生节',
        '1121': '世界问候日 世界电视日',
        '1129': '国际声援巴勒斯坦人民国际日',
        '1201': '世界艾滋病日',
        '1203': '世界残疾人日',
        '1204': '宪法日',
        '1205': '国际志愿人员日',
        '1209': '世界足球日',
        '1210': '世界人权日',
        '1212': '西安事变纪念日',
        '1213': '南京大屠杀纪念日',
        '1220': '澳门回归纪念',
        '1221': '国际篮球日',
        '1224': '平安夜',
        '1225': '圣诞节',
        '1226': '毛泽东诞辰纪念日'
    };
    //某月的第几个星期几,第3位为5表示最后一星期
    var _festival2 = {
        '0110': '黑人日',
        '0150': '世界麻风日',
        '0440': '世界儿童日',
        '0520': '国际母亲节',
        '0532': '国际牛奶日',
        '0530': '全国助残日',
        '0630': '父亲节',
        '0711': '世界建筑日',
        '0730': '被奴役国家周',
        '0936': '世界清洁地球日',
        '0932': '国际和平日',
        '0940': '国际聋人节',
        '1011': '国际住房日',
        '1024': '世界视觉日',
        '1144': '感恩节',
        '1220': '国际儿童电视广播日'
    };
    //农历节日
    var _festival3 = {
        '0101': '春节',
        '0102': '初二',
        '0103': '初三',
        '0115': '元宵节',
        '0202': '龙抬头节',
        '0323': '妈祖生辰',
        '0505': '端午节',
        '0707': '七夕节',
        '0715': '中元节',
        '0815': '中秋节',
        '0909': '重阳节',
        '1208': '腊八节',
        '1223': '小年',
        '0100': '除夕'
    };
    //假日安排数据
    var _holiday = {
        '2011': { '0402': 0, '0403': 1, '0404': 1, '0405': 1, '0430': 1, '0501': 1, '0502': 1, '0604': 1, '0605': 1, '0606': 1, '0910': 1, '0911': 1, '0912': 1, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1008': 0, '1009': 0, '1231': 0 },
        '2012': {
            '0101': 1, '0102': 1, '0103': 1, '0121': 0, '0122': 1, '0123': 1, '0124': 1, '0125': 1, '0126': 1, '0127': 1, '0128': 1, '0129': 0, '0331': 0, '0401'
                : 0, '0402': 1, '0403': 1, '0404': 1, '0428': 0, '0429': 1, '0430': 1, '0501': 1, '0622': 1, '0623': 1, '0624': 1, '0929': 0, '0930': 1, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1
        },
        '2013': { '0101': 1, '0102': 1, '0103': 1, '0105': 0, '0106': 0, '0209': 1, '0210': 1, '0211': 1, '0212': 1, '0213': 1, '0214': 1, '0215': 1, '0216': 0, '0217': 0, '0404': 1, '0405': 1, '0406': 1, '0407': 0, '0427': 0, '0428': 0, '0429': 1, '0430': 1, '0501': 1, '0608': 0, '0609': 0, '0610': 1, '0611': 1, '0612': 1, '0919': 1, '0920': 1, '0921': 1, '0922': 0, '0929': 0, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1012': 0 },
        '2014': { '0101': 1, '0126': 0, '0131': 1, '0201': 1, '0202': 1, '0203': 1, '0203': 1, '0204': 1, '0205': 1, '0206': 1, '0208': 0, '0405': 1, '0406': 1, '0407': 1, '0501': 1, '0502': 1, '0503': 1, '0504': 0, '0531': 1, '0601': 1, '0602': 1, '0908': 1, '0928': 0, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1011': 0 },
        '2015': { '0101': 1, '0102': 1, '0103': 1, '0104': 0, '0215': 0, '0218': 1, '0219': 1, '0220': 1, '0221': 1, '0222': 1, '0223': 1, '0224': 1, '0228': 0, '0404': 1, '0405': 1, '0406': 1, '0501': 1, '0502': 1, '0503': 1, '0620': 1, '0621': 1, '0622': 1, '0903': 1, '0904': 1, '0905': 1, '0906': 0, '0927': 1, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1010': 0 },
        '2016': { '0101': 1, '0102': 1, '0103': 1, '0206': 0, '0207': 1, '0208': 1, '0209': 1, '0210': 1, '0211': 1, '0212': 1, '0213': 1, '0214': 0, '0402': 1, '0403': 1, '0404': 1, '0430': 1, '0501': 1, '0502': 1, '0609': 1, '0610': 1, '0611': 1, '0612': 0, '0915': 1, '0916': 1, '0917': 1, '0918': 0, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1008': 0, '1009': 0 },
        '2017': { '0101': 1, '0102': 1, '0122': 0, '0127': 1, '0128': 1, '0129': 1, '0130': 1, '0131': 1, '0201': 1, '0202': 1, '0204': 0, '0401': 0, '0402': 1, '0403': 1, '0404': 1, '0429': 1, '0430': 1, '0501': 1, '0527': 0, '0528': 1, '0529': 1, '0530': 1, '0930': 0, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1008': 1, '1230': 1, '1231': 1 },
        '2018': { '0101': 1, '0211': 0, '0215': 1, '0216': 1, '0217': 1, '0218': 1, '0219': 1, '0220': 1, '0221': 1, '0224': 0, '0405': 1, '0406': 1, '0407': 1, '0408': 0, '0428': 0, '0429': 1, '0430': 1, '0501': 1, '0616': 1, '0617': 1, '0618': 1, '0922': 1, '0923': 1, '0924': 1, '0929': 0, '0930': 0, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1229': 0, '1230': 1, '1231': 1 },
        '2019': { '0101': 1, '0202': 0, '0203': 0, '0204': 1, '0205': 1, '0206': 1, '0207': 1, '0208': 1, '0209': 1, '0210': 1, '0405': 1, '0406': 1, '0407': 1, '0428': 0, '0501': 1, '0502': 1, '0503': 1, '0504': 1, '0505': 0, '0607': 1, '0608': 1, '0609': 1, '0913': 1, '0914': 1, '0915': 1, '0929': 0, '1001': 1, '1002': 1, '1003': 1, '1004': 1, '1005': 1, '1006': 1, '1007': 1, '1012': 0 }
    };
    //获取日期数据
    var getDateObj = function (year, month, day) {
        var date = arguments.length && year ? new Date(year, month - 1, day) : new Date();
        return {
            'year': date.getFullYear(),
            'month': date.getMonth() + 1,
            'day': date.getDate(),
            'week': date.getDay()
        };
    };
    //当天
    var _today = getDateObj();
    //获取当月天数
    var getMonthDays = function (obj) {
        var day = new Date(obj.year, obj.month, 0);
        return day.getDate();
    };
    if (!String.prototype.trim) {
        String.prototype.trim = function () {
            return this.replace(/^\s+|\s+$/g, '');
        };
    }
    //获取某天日期信息
    var getDateInfo = function (obj) {
        var info = calendar.solar2lunar(obj.year, obj.month, obj.day);
        var cMonth = info.cMonth > 9 ? '' + info.cMonth : '0' + info.cMonth;
        var cDay = info.cDay > 9 ? '' + info.cDay : '0' + info.cDay;
        var lMonth = info.lMonth > 9 ? '' + info.lMonth : '0' + info.lMonth;
        var lDay = info.lDay > 9 ? '' + info.lDay : '0' + info.lDay;
        var code1 = cMonth + cDay;
        var code2 = cMonth + Math.ceil(info.cDay / 7) + info.nWeek % 7;
        var code3 = lMonth + lDay;
        var days = getMonthDays(obj);
        //节日信息
        info['festival'] = '';
        if (_festival3[code3]) {
            info['festival'] += _festival3[code3];
        }
        if (_festival1[code1]) {
            info['festival'] += ' ' + _festival1[code1];
        }
        if (_festival2[code2]) {
            info['festival'] += ' ' + _festival2[code2];
        }
        if (obj['day'] + 7 > days) {
            var code4 = cMonth + 5 + info.nWeek % 7;
            if (code4 != code2 && _festival2[code4]) {
                info['festival'] += ' ' + _festival2[code4];
            }
        }
        info['festival'] = info['festival'].trim();
        //放假、调休等标记
        info['sign'] = '';
        if (_holiday[info.cYear]) {
            var holiday = _holiday[info.cYear];
            if (typeof holiday[code1] != 'undefined') {
                info['sign'] = holiday[code1] ? 'holiday' : 'work';
            }
        }
        if (info.cYear == _today.year && info.cMonth == _today.month && info.cDay == _today.day) {
            info['sign'] = 'today';
        }
        return info;
    };
    //获取日历信息
    return (function (date) {
        var date = date || _today;
        var first = getDateObj(date['year'], date['month'], 1);		//当月第一天
        var days = getMonthDays(date);							//当月天数
        var data = [];										//日历信息
        var obj = {};
        //上月日期
        for (var i = first['week']; i > 0; i--) {
            obj = getDateObj(first['year'], first['month'], first['day'] - i);
            var info = getDateInfo(obj);
            info['disabled'] = 1;
            data.push(info);
        }
        //当月日期
        for (var i = 0; i < days; i++) {
            obj = {
                'year': first['year'],
                'month': first['month'],
                'day': first['day'] + i,
                'week': (first['week'] + i) % 7
            };
            var info = getDateInfo(obj);
            info['disabled'] = 0;
            data.push(info);
        }
        //下月日期
        var last = obj;
        for (var i = 1; last['week'] + i < 7; i++) {
            obj = getDateObj(last['year'], last['month'], last['day'] + i);
            var info = getDateInfo(obj);
            info['disabled'] = 1;
            data.push(info);
        }
        return {
            'date': getDateInfo(date),				//当前日历选中日期
            'data': data
        };
    });
})();



var d = new Date();

var lunarInfo = getLunarData({
    'year': d.getFullYear(),
    'month': d.getMonth() + 1,
    'day': d.getDate()
});

// console.log(JSON.stringify(lunarInfo, 2));

/*
"date": {
    "lYear": 2022,
    "lMonth": 1,
    "lDay": 14,
    "Animal": "虎",
    "IMonthCn": "正月",
    "IDayCn": "十四",
    "cYear": 2022,
    "cMonth": 2,
    "cDay": 14,
    "gzYear": "壬寅",
    "gzMonth": "壬寅",
    "gzDay": "戊戌",
    "isToday": true,
    "isLeap": false,
    "nWeek": 1,
    "ncWeek": "星期一",
    "isTerm": false,
    "Term": null,
    "festival": "情人节",
    "sign": "today"
  },

*/

let today = lunarInfo.date;

let linearGradient = {
    type: "linear",
    colors: ["red", "yellow"],
    startPoint: "top",
    endPoint: "bottom",
};

$render(
    <vstack
        background={$gradient(linearGradient)}
        frame="max,center"
    >
        <hstack>
            <text font="title2">{today.Animal} 年</text>

            <vstack>
                <text font="title">{today.IMonthCn}</text>
                <text font="title">{today.IDayCn}</text>
            </vstack>
        </hstack>

        <text font="caption">{today.festival}</text>

    </vstack>
);

