//
// When setting up the widget provide a parameter
// in the setup dialog like Please provide a parameter like
// '2022-11-26 Vacation' if you want to count down
// or up to a date or '2022-11-26T12:35:00 Flight'
// if you want to count up or down to a specific time
// on a date.
//

const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = SECONDS_PER_MINUTE * 60;
const SECONDS_PER_DAY = SECONDS_PER_HOUR * 24;

function is_leap(yr) {
  return yr % 400 === 0 || (yr % 4 === 0 && yr % 100 !== 0);
}

function days_per_month(month, year) {
  if (month === 1) {
    if (is_leap(year)) {
      return 29;
    } else {
      return 28;
    }
  } else {
    months = [31, 0, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    return months[month];
  }
}

function months_to_days(month) {
  return Math.floor((month * 3057 - 3007) / 100);
}

function years_to_days(yr) {
  return (
    yr * 365 + Math.floor(yr / 4) - Math.floor(yr / 100) + Math.floor(yr / 400)
  );
}

function ymd_to_days(yr, mo, day) {
  scalar = day + months_to_days(mo);
  if (mo > 2)
    // adjust if past February
    scalar -= is_leap(yr) ? 1 : 2;
  yr--;
  scalar += years_to_days(yr);
  return scalar;
}

function determine_sign(remainder, large_unit, small_unit) {
  if (remainder > large_unit - Math.floor(small_unit / 2)) {
    return { text: "≈", count: 1 };
  } else if (remainder > Math.floor(large_unit / 2)) {
    return { text: "<", count: 1 };
  } else if (remainder > Math.floor(small_unit / 2)) {
    return { text: ">", count: 0 };
  } else if (remainder > 0) {
    return { text: "≈", count: 0 };
  } else {
    return { text: "", count: 0 };
  }
}

function Countdown(target, countdown_to) {
  // Convert target and now to tm formats
  const now_date = new Date();
  now_tm = {
    tm_min: countdown_to === "T" ? now_date.getMinutes() : 0,
    tm_hour: countdown_to === "T" ? now_date.getHours() : 0,
    tm_mday: now_date.getDate(),
    tm_mon: now_date.getMonth(),
    tm_year: now_date.getFullYear(),
  };
  const target_date = target;
  target_tm = {
    tm_min: countdown_to === "T" ? target_date.getMinutes() : 0,
    tm_hour: countdown_to === "T" ? target_date.getHours() : 0,
    tm_mday: target_date.getDate(),
    tm_mon: target_date.getMonth(),
    tm_year: target_date.getFullYear(),
  };

  // Choose post-text, max_tm and min_tm
  if (target_date.getTime() > now_date.getTime()) {
    // Count down to
    post_text = "";
    max_tm = target_tm;
    min_tm = now_tm;
  } else {
    // Count down to
    post_text = "ago";
    max_tm = now_tm;
    min_tm = target_tm;
  }

  // Calculate differences in years, months, days, hours and minutes
  received = min_tm.tm_min > max_tm.tm_min ? 60 : 0;
  min_diff = max_tm.tm_min + received - min_tm.tm_min;
  borrow = received > 0 ? 1 : 0;
  received = min_tm.tm_hour + borrow > max_tm.tm_hour ? 24 : 0;
  hour_diff = max_tm.tm_hour + received - min_tm.tm_hour - borrow;
  borrow = received > 0 ? 1 : 0;
  received =
    min_tm.tm_mday + borrow > max_tm.tm_mday
      ? days_per_month(max_tm.tm_mon, max_tm.tm_year)
      : 0;
  day_diff = max_tm.tm_mday + received - min_tm.tm_mday - borrow;
  borrow = received > 0 ? 1 : 0;
  received = min_tm.tm_mon + borrow > max_tm.tm_mon ? 12 : 0;
  month_diff = max_tm.tm_mon + received - min_tm.tm_mon - borrow;
  borrow = received > 0 ? 1 : 0;
  year_diff = max_tm.tm_year - min_tm.tm_year - borrow;

  // Calculate total difference in seconds
  diff =
    ymd_to_days(max_tm.tm_year + 1900, max_tm.tm_mon + 1, max_tm.tm_mday) -
    ymd_to_days(min_tm.tm_year + 1900, min_tm.tm_mon + 1, min_tm.tm_mday);
  if (
    min_tm.tm_hour * 100 + min_tm.tm_min >
    max_tm.tm_hour * 100 + max_tm.tm_min
  )
    diff -= 1;
  diff = diff * 24 + hour_diff;
  diff = diff * 60 + min_diff;
  diff = diff * 60;

  if (diff == 0 || (countdown_to == 'D' && diff == SECONDS_PER_DAY)) {
    // Display one word
    if (diff == 0) {
      if (countdown_to == 'D') {
        return "Today";
      } else {
        return "Now";
      }
    } else {
      if (target_date.getTime() > now_date.getTime()) {
        return "Tomorrow";
      } else {
        return "Yesterday";
      }
    }
  }

  // Display incremental detail
  count = 0;
  remainder = 0;
  if (
    year_diff > 3 ||
    (year_diff == 3 &&
      (month_diff > 0 || day_diff > 0 || hour_diff > 0 || min_diff > 0))
  ) {
    count = year_diff;
    remainder =
      ymd_to_days(
        max_tm.tm_year - year_diff + 1900,
        max_tm.tm_mon + 1,
        max_tm.tm_mday
      ) - ymd_to_days(min_tm.tm_year + 1900, min_tm.tm_mon + 1, min_tm.tm_mday);
    remainder *= SECONDS_PER_DAY;
    remainder += hour_diff * SECONDS_PER_HOUR + min_diff * SECONDS_PER_MINUTE;
    sign = determine_sign(
      remainder,
      (is_leap(max_tm.tm_year + 1900) ? 366 : 365) * SECONDS_PER_DAY,
      SECONDS_PER_DAY
    );
    pre_text = sign.text;
    count += sign.count;
    unit = " years ";
  } else if (
    year_diff * 12 + month_diff > 3 ||
    (month_diff == 3 && (day_diff > 0 || hour_diff > 0 || min_diff > 0))
  ) {
    count = year_diff * 12 + month_diff;
    remainder =
      day_diff * SECONDS_PER_DAY +
      hour_diff * SECONDS_PER_HOUR +
      min_diff * SECONDS_PER_MINUTE;
    sign = determine_sign(
      remainder,
      days_per_month(max_tm.tm_mon, max_tm.tm_year) * SECONDS_PER_DAY,
      SECONDS_PER_DAY
    );
    pre_text = sign.text;
    count += sign.count;
    unit = " months ";
  } else if (diff > 3 * 7 * SECONDS_PER_DAY) {
    count = Math.floor(diff / (7 * SECONDS_PER_DAY));
    remainder = diff % (7 * SECONDS_PER_DAY);
    sign = determine_sign(remainder, 7 * SECONDS_PER_DAY, SECONDS_PER_DAY);
    pre_text = sign.text;
    count += sign.count;
    unit = " weeks ";
  } else if (diff > 3 * SECONDS_PER_DAY || countdown_to === "D") {
    count = Math.floor(diff / SECONDS_PER_DAY);
    remainder = diff % SECONDS_PER_DAY;
    sign = determine_sign(remainder, SECONDS_PER_DAY, SECONDS_PER_HOUR);
    pre_text = sign.text;
    count += sign.count;
    unit = " days ";
  } else if (diff > 3 * SECONDS_PER_HOUR) {
    count = Math.floor(diff / SECONDS_PER_HOUR);
    remainder = diff % SECONDS_PER_HOUR;
    sign = determine_sign(remainder, SECONDS_PER_HOUR, SECONDS_PER_MINUTE);
    pre_text = sign.text;
    count += sign.count;
    unit = " hours ";
  } else if (diff > SECONDS_PER_MINUTE) {
    count = Math.floor(diff / SECONDS_PER_MINUTE);
    pre_text = "";
    unit = " minutes ";
  } else {
    count = 1;
    pre_text = "";
    unit = " minute ";
  }

  return pre_text + count + unit + post_text;
}

// Retrieve target from widget parameter
const demoYear = new Date().getFullYear() + 1;
const param = ($getenv("widget-param") || `${demoYear}-01-01 New Year`).trim();
const dtre = /\d\d\d\d\-\d\d\-\d\d(T\d\d\:\d\d\:\d\d)?/;
dt_param = param.match(dtre);
if (!dt_param) {
  $render(
    <vstack frame="max" background="#7f1d1d" padding="14">
      <icon systemName="calendar.badge.exclamationmark" size="28" color="#fecaca"/>
      <text font="headline" color="white">Use YYYY-MM-DD Event</text>
      <text font="caption" color="#fecaca">Example: 2027-01-01 New Year</text>
    </vstack>
  );
  return;
} else {
  target = new Date(dt_param[0]);
  event = param.replace(dtre, "").trim();
  countdown_to = dt_param[1] ? "T" : "D";
}

// Update widget
text = Countdown(target, countdown_to);

let linearGradient = {
  type: "linear",
  colors: ["#fb5a72", "#f5243b"],
  startPoint: "top",
  endPoint: "bottom",
};

// Date formatting
if (countdown_to === "T") {
  var dateFormat = {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
  };
} else {
  var dateFormat = {
    year: "numeric",
    month: "short",
    day: "numeric",
  };
}

$render(
  <vstack
    background={$gradient(linearGradient)}
    frame="max"
    alignment="leading"
    padding="14"
  >
    <hstack frame="max">
      <vstack alignment="leading">
        <text font="body" color="white">
          {event}
        </text>
        <text font="caption" color="white">
          {target.toLocaleDateString(undefined, dateFormat)}
        </text>
      </vstack>
      <spacer />
    </hstack>
    <spacer />
    <text font="title" weight="bold" color="white">
      {text}
    </text>
  </vstack>
);
