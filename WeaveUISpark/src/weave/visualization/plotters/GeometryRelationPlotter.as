package weave.visualization.plotters
{
	import flash.display.Graphics;
	import flash.display.Shape;
	import flash.geom.Point;
	import flash.utils.Dictionary;
	
	import weave.api.WeaveAPI;
	import weave.api.data.ColumnMetadata;
	import weave.api.data.DataTypes;
	import weave.api.data.IAttributeColumn;
	import weave.api.data.IKeySet;
	import weave.api.data.IProjector;
	import weave.api.data.IQualifiedKey;
	import weave.api.data.ISimpleGeometry;
	import weave.api.detectLinkableObjectChange;
	import weave.api.linkSessionState;
	import weave.api.newDisposableChild;
	import weave.api.newLinkableChild;
	import weave.api.primitives.IBounds2D;
	import weave.api.registerLinkableChild;
	import weave.api.ui.IPlotTask;
	import weave.api.ui.IPlotterWithGeometries;
	import weave.core.LinkableNumber;
	import weave.core.LinkableString;
	import weave.data.AttributeColumns.DynamicColumn;
	import weave.data.AttributeColumns.FilteredColumn;
	import weave.data.AttributeColumns.ReprojectedGeometryColumn;
	import weave.data.QKeyManager;
	import weave.primitives.GeneralizedGeometry;
	import weave.utils.BitmapText;
	import weave.utils.ColumnUtils;
	import weave.utils.DrawUtils;
	import weave.visualization.layers.PlotTask;

	// Refer to Feature #924 for detail description
	public class GeometryRelationPlotter extends AbstractPlotter implements IPlotterWithGeometries
	{
		public function GeometryRelationPlotter()
		{
			registerSpatialProperty(geometryColumn);
			
			// set up x,y columns to be derived from the geometry column
			linkSessionState(geometryColumn, dataX.requestLocalObject(ReprojectedGeometryColumn, true));
			linkSessionState(geometryColumn, dataY.requestLocalObject(ReprojectedGeometryColumn, true));
			setColumnKeySources([geometryColumn]);
		}
		// Need to set columns dataType in AdminConsole
		public const geometryColumn:ReprojectedGeometryColumn = newSpatialProperty(ReprojectedGeometryColumn);
		public const sourceKeyColumn:DynamicColumn = newSpatialProperty(DynamicColumn);
		public const destinationKeyColumn:DynamicColumn = newSpatialProperty(DynamicColumn);
		public const valueColumn:DynamicColumn = newLinkableChild(this, DynamicColumn);
		public const lineWidth:LinkableNumber = registerLinkableChild(this, new LinkableNumber(5));
		public const posLineColor:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0xFF0000));
		public const negLineColor:LinkableNumber = registerLinkableChild(this, new LinkableNumber(0x0000FF));
		
		
		protected const filteredDataX:FilteredColumn = newDisposableChild(this, FilteredColumn);
		protected const filteredDataY:FilteredColumn = newDisposableChild(this, FilteredColumn);
		
		public function get dataX():DynamicColumn
		{
			return filteredDataX.internalDynamicColumn;
		}
		public function get dataY():DynamicColumn
		{
			return filteredDataY.internalDynamicColumn;
		}
		
		public const sourceProjection:LinkableString = newSpatialProperty(LinkableString);
		public const destinationProjection:LinkableString = newSpatialProperty(LinkableString);
		
		private const bitmapText:BitmapText = new BitmapText();
		protected const tempSourcePoint:Point = new Point();
		protected const tempDestinationPoint:Point = new Point();
		protected const tempGeometryPoint:Point = new Point();
		private var _projector:IProjector;
		private var _xCoordCache:Dictionary;
		private var _yCoordCache:Dictionary;
		
		/**
		 * This gets called whenever any of the following change: dataX, dataY, sourceProjection, destinationProjection
		 */		
		private function updateProjector():void
		{
			_xCoordCache = new Dictionary(true);
			_yCoordCache = new Dictionary(true);
			
			var sourceSRS:String = sourceProjection.value;
			var destinationSRS:String = destinationProjection.value;
			
			// if sourceSRS is missing and both X and Y projections are the same, use that.
			if (!sourceSRS)
			{
				var projX:String = dataX.getMetadata(ColumnMetadata.PROJECTION);
				var projY:String = dataY.getMetadata(ColumnMetadata.PROJECTION);
				if (projX == projY)
					sourceSRS = projX;
			}
			
			if (sourceSRS && destinationSRS)
				_projector = WeaveAPI.ProjectionManager.getProjector(sourceSRS, destinationSRS);
			else
				_projector = null;
		}
		
		protected function getCoordsFromRecordKey(recordKey:IQualifiedKey, output:Point):void
		{
			if (detectLinkableObjectChange(updateProjector, dataX, dataY, sourceProjection, destinationProjection))
				updateProjector();
			
			if (_xCoordCache[recordKey] !== undefined)
			{
				output.x = _xCoordCache[recordKey];
				output.y = _yCoordCache[recordKey];
				return;
			}
			
			for (var i:int = 0; i < 2; i++)
			{
				var result:Number = NaN;
				var dataCol:IAttributeColumn = i == 0 ? dataX : dataY;
				if (dataCol.getMetadata(ColumnMetadata.DATA_TYPE) == DataTypes.GEOMETRY)
				{
					var geoms:Array = dataCol.getValueFromKey(recordKey) as Array;
					var geom:GeneralizedGeometry;
					if (geoms && geoms.length)
						geom = geoms[0] as GeneralizedGeometry;
					if (geom)
					{
						if (i == 0)
							result = geom.bounds.getXCenter();
						else
							result = geom.bounds.getYCenter();
					}
				}
				else
				{
					result = dataCol.getValueFromKey(recordKey, Number);
				}
				
				if (i == 0)
				{
					output.x = result;
					_xCoordCache[recordKey] = result;
				}
				else
				{
					output.y = result;
					_yCoordCache[recordKey] = result;
				}
			}
			if (_projector)
			{
				_projector.reproject(output);
				_xCoordCache[recordKey] = output.x;
				_yCoordCache[recordKey] = output.y;
			}
		}
		
		/**
		 * The data bounds for a glyph has width and height equal to zero.
		 * This function returns a Bounds2D object set to the data bounds associated with the given record key.
		 * @param key The key of a data record.
		 * @param outputDataBounds A Bounds2D object to store the result in.
		 */
		override public function getDataBoundsFromRecordKey(recordKey:IQualifiedKey):Array
		{
			getCoordsFromRecordKey(recordKey, tempGeometryPoint);
			var Bounds:IBounds2D = getReusableBounds();
			Bounds.setCenteredRectangle(tempGeometryPoint.x, tempGeometryPoint.y, 0, 0);
			if (isNaN(tempGeometryPoint.x))
				Bounds.setXRange(-Infinity, Infinity);
			if (isNaN(tempSourcePoint.y))
				Bounds.setYRange(-Infinity, Infinity);
			return [Bounds];
		}
		
		override public function drawPlotAsyncIteration(task:IPlotTask):Number
		{
			// Make sure all four column are populated
			if (sourceKeyColumn.keys.length == 0 || destinationKeyColumn.keys.length == 0 || valueColumn.keys.length == 0 || geometryColumn.keys.length == 0) return 1;
			
			// this template from AbstractPlotter will draw one record per iteration
			if (task.iteration < task.recordKeys.length)
			{
				//------------------------
				// draw one record
				var geoKey:IQualifiedKey = task.recordKeys[task.iteration] as IQualifiedKey;
				tempShape.graphics.clear();

				getCoordsFromRecordKey(geoKey, tempSourcePoint); // Get source coordinate
				task.dataBounds.projectPointTo(tempSourcePoint, task.screenBounds);

				// Loop over the data table to find all the row keys with this source key value
				var tempRowKeys:Array = new Array();
				for (var i:int = 0; i < sourceKeyColumn.keys.length; i++)
				{
					if (sourceKeyColumn.getValueFromKey(sourceKeyColumn.keys[i], IQualifiedKey) == geoKey)
						tempRowKeys.push(sourceKeyColumn.keys[i]);
				}
				
				// Draw lines from source to destinations
				var max:Number; // Absoulte max used for normalization
				if (WeaveAPI.StatisticsCache.getColumnStatistics(valueColumn).getMax() > -WeaveAPI.StatisticsCache.getColumnStatistics(valueColumn).getMin())
					max = WeaveAPI.StatisticsCache.getColumnStatistics(valueColumn).getMax();
				else
					max = WeaveAPI.StatisticsCache.getColumnStatistics(valueColumn).getMin();
				
				// Value normalization
				for (var j:int = 0; j < tempRowKeys.length; j++)
				{
					if (valueColumn.getValueFromKey(tempRowKeys[j], Number) > 0)
					{
						tempShape.graphics.lineStyle(Math.round((valueColumn.getValueFromKey(tempRowKeys[j], Number) / max) * lineWidth.value), posLineColor.value);
					}
					else
					{
						tempShape.graphics.lineStyle(-Math.round((valueColumn.getValueFromKey(tempRowKeys[j], Number) / max) * lineWidth.value), negLineColor.value);
					}
					
					tempShape.graphics.moveTo(tempSourcePoint.x, tempSourcePoint.y);
					getCoordsFromRecordKey(destinationKeyColumn.getValueFromKey(tempRowKeys[j], IQualifiedKey), tempDestinationPoint); // Get destionation coordinate
					task.dataBounds.projectPointTo(tempDestinationPoint, task.screenBounds);
					tempShape.graphics.lineTo(tempDestinationPoint.x, tempDestinationPoint.y);

//					DrawUtils.drawCurvedLine(tempShape.graphics, tempSourcePoint.x, tempSourcePoint.y, tempDestinationPoint.x, tempDestinationPoint.y, 1);
					
					bitmapText.x = Math.round((tempSourcePoint.x + tempDestinationPoint.x) / 2);
					bitmapText.y = Math.round((tempSourcePoint.y + tempDestinationPoint.y) / 2);
					bitmapText.text = valueColumn.getValueFromKey(tempRowKeys[j], Number);
					bitmapText.draw(task.buffer);
				}
				
				task.buffer.draw(tempShape);
				
				//------------------------
				
				// report progress
				return task.iteration / task.recordKeys.length;
			}
			
			// report progress
			return 1; // avoids division by zero in case task.recordKeys.length == 0
		}
		
		public function getGeometriesFromRecordKey(recordKey:IQualifiedKey, minImportance:Number = 0, bounds:IBounds2D = null):Array
		{
			var results:Array = [];
			
//			// push three geometries between each column
//			var x:Number, y:Number;
//			var prevX:Number, prevY:Number;
//			var geometry:ISimpleGeometry;
//			for (var i:int = 0; i < _columns.length; ++i)
//			{
//				x = i;
//				y = (_columns[i] as IAttributeColumn).getValueFromKey(recordKey, Number);
//				
//				if (i > 0)
//				{
//					if (isFinite(y) && isFinite(prevY))
//					{
//						geometry = new SimpleGeometry(GeometryType.LINE);
//						geometry.setVertices([new Point(prevX, prevY), new Point(x, y)]);
//						results.push(geometry);
//					}
//					else
//					{
//						// case where current coord is defined and previous coord is missing
//						if (isFinite(y))
//						{
//							geometry = new SimpleGeometry(GeometryType.POINT);
//							geometry.setVertices([new Point(x, y)]);
//							results.push(geometry);
//						}
//						// special case where i == 1 and y0 (prev) is defined and y1 (current) is missing
//						if (i == 1 && isFinite(prevY))
//						{
//							geometry = new SimpleGeometry(GeometryType.POINT);
//							geometry.setVertices([new Point(prevX, prevY)]);
//							results.push(geometry);
//						}
//					}
//				}
//				
//				prevX = x;
//				prevY = y;
//			}
			
			return results;
		}
		
		public function getBackgroundGeometries():Array
		{
			return [];
		}
		
	}
}