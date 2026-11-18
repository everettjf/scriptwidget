// Designed for the large widget; the small and medium sizes show the essentials. widget-param: sleepHours,waterGlasses,steps,mood
const values = ($getenv("widget-param") || "7.5,6,6840,Calm").split(",");
const sleep = Number(values[0]) || 0;
const water = Number(values[1]) || 0;
const steps = Number(values[2]) || 0;
const mood = (values[3] || "Steady").trim();
const score = Math.round(Math.min(100, (sleep / 8) * 35 + (water / 8) * 25 + (steps / 10000) * 40));

const Metric = ({ icon, title, value, detail, color, progress, total }) => (
  <vstack
    frame="max,74,leading"
    alignment="leading"
    spacing="5"
    padding="10"
    background="#172033"
    corner="13"
  >
    <hstack>
      <icon systemName={icon} size="16" color={color} />
      <spacer />
      <text font="caption2" color="#94a3b8">
        {title}
      </text>
    </hstack>
    <hstack alignment="bottom">
      <text font="headline" weight="bold" color="white">
        {value}
      </text>
      <spacer />
      <text font="caption2" color="#94a3b8">
        {detail}
      </text>
    </hstack>
    <progress value={progress} total={total} thickness="5" color={color} trackColor="#273449" />
  </vstack>
);

const size = $getenv("widget-size");
if (size === "small") {
  // Small: the balance score.
  $render(
    <vstack frame="max" spacing="8" padding="14" background="#312e81">
      <text font="caption" weight="bold" color="#c4b5fd">
        DAILY BALANCE
      </text>
      <zstack frame="84,84">
        <ring
          value={score / 100}
          thickness="8"
          color="#a78bfa"
          trackColor="#49356d"
          frame="84,84"
        />
        <text font="title2" weight="bold" color="white">
          {score}
        </text>
      </zstack>
      <badge text={mood.toUpperCase()} color="#c4b5fd" />
    </vstack>,
  );
} else if (size === "medium") {
  // Medium: the balance score above the three numbers.
  const Figure = ({ icon, title, value, color }) => (
    <vstack
      frame="max,56,leading"
      alignment="leading"
      spacing="3"
      padding="9"
      background="#172033"
      corner="12"
    >
      <hstack spacing="5">
        <icon systemName={icon} size="12" color={color} />
        <text font="caption2" color="#94a3b8">
          {title}
        </text>
        <spacer />
      </hstack>
      <text font="subheadline" weight="semibold" color="white">
        {value}
      </text>
    </vstack>
  );
  $render(
    <vstack frame="max" alignment="leading" spacing="8" padding="14" background="#312e81">
      <hstack spacing="12" padding="10" background="#5b21b6" corner="15">
        <zstack frame="48,48">
          <ring
            value={score / 100}
            thickness="6"
            color="#a78bfa"
            trackColor="#49356d"
            frame="48,48"
          />
          <text font="subheadline" weight="bold" color="white">
            {score}
          </text>
        </zstack>
        <vstack alignment="leading" spacing="3">
          <hstack spacing="6">
            <text font="caption" weight="bold" color="#c4b5fd">
              DAILY BALANCE
            </text>
            <text font="caption" color="#ddd6fe">
              · {mood}
            </text>
          </hstack>
          <text font="headline" weight="bold" color="white">
            Good momentum
          </text>
        </vstack>
        <spacer />
      </hstack>
      <hstack spacing="8">
        <Figure icon="bed.double.fill" title="SLEEP" value={`${sleep}h`} color="#818cf8" />
        <Figure icon="drop.fill" title="WATER" value={`${water}/8`} color="#38bdf8" />
        <Figure icon="figure.walk" title="STEPS" value={steps.toLocaleString()} color="#34d399" />
      </hstack>
    </vstack>,
  );
} else {
  $render(
    <vstack frame="max" alignment="leading" spacing="10" padding="16" background="#312e81">
      <hstack>
        <vstack alignment="leading" spacing="2">
          <text font="title2" weight="bold" color="white">
            Wellness Today
          </text>
          <text font="caption" color="#94a3b8">
            Small choices, steady energy
          </text>
        </vstack>
        <spacer />
        <badge text={mood.toUpperCase()} color="#c4b5fd" />
      </hstack>
      <hstack spacing="12" padding="12" background="#5b21b6" corner="15">
        <progress
          style="circular"
          frame="52"
          value={score}
          total="100"
          thickness="7"
          label={`${score}`}
          color="#a78bfa"
          trackColor="#49356d"
        />
        <vstack alignment="leading" spacing="3">
          <text font="caption" weight="bold" color="#c4b5fd">
            DAILY BALANCE
          </text>
          <text font="headline" weight="bold" color="white">
            Good momentum
          </text>
          <text font="caption" color="#ddd6fe">
            Add one glass and a short walk.
          </text>
        </vstack>
        <spacer />
      </hstack>
      <hstack spacing="10">
        <Metric
          icon="bed.double.fill"
          title="SLEEP"
          value={`${sleep}h`}
          detail="8h target"
          color="#818cf8"
          progress={sleep}
          total="8"
        />
        <Metric
          icon="drop.fill"
          title="WATER"
          value={`${water}/8`}
          detail="glasses"
          color="#38bdf8"
          progress={water}
          total="8"
        />
      </hstack>
      <Metric
        icon="figure.walk"
        title="MOVEMENT"
        value={steps.toLocaleString()}
        detail="10,000 step target"
        color="#34d399"
        progress={steps}
        total="10000"
      />
    </vstack>,
  );
}
