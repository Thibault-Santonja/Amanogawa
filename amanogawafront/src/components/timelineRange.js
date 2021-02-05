import React, {useState} from 'react';

// Timeline Range Slider
import Slider from '@material-ui/core/Slider';


function valuetext(value) {
    return `${value}`;
}

function setMarks(timelineRange) {
    const step = 100;
    let label;
    let marks = [
        {
            value: timelineRange.end,
            label: 'Today',
        },
    ];

    for (let i = timelineRange.start / step; i < Math.floor(timelineRange.end / step); i++) {
        if (i !== 0)
            label = (i * step).toString()
        else
            label = 'JC'

        marks.push({
            value: i * step,
            label: label
        })
    }

    return marks;
}


export default function TimelineSlider(props) {
    const timelineRange = {start:props.startTime, end:props.endTime};
    const marks = setMarks(timelineRange)
    const [dateRange, setDateRange] = useState([0, timelineRange.end]);

    const handleChange = (event, newValue) => {
        setDateRange(newValue);
    };

    return (<Slider
        value={dateRange}
        onChange={handleChange}
        valueLabelDisplay="auto"
        aria-labelledby="range-slider"
        getAriaValueText={valuetext}
        min={timelineRange.start}
        max={timelineRange.end}
        marks={marks}
    />);
}